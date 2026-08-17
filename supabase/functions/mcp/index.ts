/*============================================================================
  mcp/index.ts — an MCP server over the rep portal, for Claude and anything
  else that speaks Model Context Protocol.

  Transport: Streamable HTTP, stateless, JSON responses only.
  ----------------------------------------------------------
  One POST carries one JSON-RPC message and gets one JSON response back. No
  sessions, no SSE stream, no server-initiated messages — all of which the
  spec makes optional, and none of which a query-the-warehouse server needs.
  Statelessness is what lets this live in an Edge Function at all: any
  instance can answer any request, because the only state is the bearer token
  the client sends every time.

  Authentication and why this function is a fifth Edge Function
  -------------------------------------------------------------
  functions/README.md admits only code that holds a secret or needs
  service_role. This qualifies on both counts, narrowly: it holds
  MCP_JWT_SECRET, and it makes exactly one service_role call — resolving a
  token to a user id — before dropping to a client scoped to that user. It
  cannot be a Postgres function with `security definer` instead, which is the
  first question that file tells you to ask, because MCP is an HTTP protocol
  and PostgREST does not speak it.

  Everything past the door is ordinary RLS. See _shared/mcpAuth.ts for the
  handover, and mcp/tools.ts for the rule that no tool may scope by customer
  in TypeScript.

  Deploy: supabase functions deploy mcp --no-verify-jwt
  (--no-verify-jwt because the gateway's check would reject an MCP token — it
  is not a Supabase JWT — and this function authenticates every request
  itself before reading anything.)
============================================================================*/

import { HttpError } from '../_shared/supabase.ts'
import { callerClient, extractToken, resolveCaller } from '../_shared/mcpAuth.ts'
import { describeTool, ToolError, TOOLS, TOOLS_BY_NAME } from './tools.ts'

const SERVER_NAME = 'christensen-rep-portal'
const SERVER_VERSION = '1.0.0'

/** Newest first. We answer in the client's version when we know it. */
const SUPPORTED_PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05']

/**
 * Sent once at initialize. Worth the tokens: without it a model asks for
 * "sales numbers" and gets bookings when it wanted invoiced revenue, which
 * is the one distinction this dataset punishes you for missing.
 */
const INSTRUCTIONS = `
Sales data for a Christensen Arms rep territory, read-only.

Scope is automatic: every tool returns only the accounts assigned to the
connected rep. There is no way to widen it and no need to filter for it.

Start with \`whoami\` — it reports \`data_through\`, the newest invoice date in
the warehouse. The data is loaded nightly, so "today" in the ERP is that date,
not the calendar date.

Three money words that are NOT interchangeable:
  • revenue / invoiced — shipped and billed. This is what "sales" means here.
  • bookings / order value — placed, not yet shipped.
  • backlog — the unshipped remainder of open orders. Money owed, not earned.

Typical path: \`get_territory_summary\` for the shape of the book →
\`list_territory_accounts\` to rank → \`search_accounts\` to resolve a name to a
customer_key → \`get_account\` for the full picture → \`get_account_sku_sales\`,
\`list_orders\`, \`list_backlog\` for detail. \`get_sales_summary\` answers
"this month / last month / trend" at monthly grain.

Figures are US dollars and calendar-year to date. Goal pace is seasonal, not
straight-line, so an account behind on days can still be on pace.
`.trim()

/*----------------------------------------------------------------------------
  CORS. Wider than _shared/cors.ts because MCP clients are not just our SPA:
  browser-based ones send the protocol-version header and preflight GET and
  DELETE as well as POST.
----------------------------------------------------------------------------*/
const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': Deno.env.get('MCP_ALLOWED_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers':
    'authorization, content-type, accept, apikey, x-client-info, ' +
    'x-mcp-token, mcp-protocol-version, mcp-session-id, last-event-id',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Expose-Headers': 'mcp-protocol-version, mcp-session-id',
  'Access-Control-Max-Age': '86400',
  Vary: 'Origin',
}

function jsonResponse(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, ...extra, 'Content-Type': 'application/json' },
  })
}

/*----------------------------------------------------------------------------
  JSON-RPC
----------------------------------------------------------------------------*/
type Id = string | number | null

interface RpcMessage {
  jsonrpc?: string
  id?: Id
  method?: string
  params?: Record<string, unknown>
}

const RPC = {
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL: -32603,
} as const

function rpcResult(id: Id, result: unknown) {
  return { jsonrpc: '2.0', id, result }
}

function rpcError(id: Id, code: number, message: string, data?: unknown) {
  return { jsonrpc: '2.0', id, error: data === undefined ? { code, message } : { code, message, data } }
}

/*----------------------------------------------------------------------------
  Method dispatch. `ctx` is built lazily — `initialize` and `tools/list` need
  the caller's identity for nothing, but authentication has already happened
  by the time we get here, so there is no fast path worth the branch.
----------------------------------------------------------------------------*/
async function dispatch(
  message: RpcMessage,
  ctx: { db: Awaited<ReturnType<typeof callerClient>>; caller: Awaited<ReturnType<typeof resolveCaller>> },
): Promise<unknown | null> {
  const id = message.id ?? null
  const method = message.method ?? ''
  const params = message.params ?? {}

  switch (method) {
    case 'initialize': {
      const asked = String((params as { protocolVersion?: unknown }).protocolVersion ?? '')
      const version = SUPPORTED_PROTOCOLS.includes(asked) ? asked : SUPPORTED_PROTOCOLS[0]
      return rpcResult(id, {
        protocolVersion: version,
        capabilities: { tools: { listChanged: false } },
        serverInfo: {
          name: SERVER_NAME,
          title: 'Christensen Rep Portal',
          version: SERVER_VERSION,
        },
        instructions: INSTRUCTIONS,
      })
    }

    case 'ping':
      return rpcResult(id, {})

    case 'tools/list':
      // No pagination: twenty tools fit in one response, and a nextCursor
      // nobody needs is a round trip every client pays on every connect.
      return rpcResult(id, { tools: TOOLS.map(describeTool) })

    // Declared in neither direction, but clients probe them on connect and an
    // empty list is a friendlier answer than "method not found".
    case 'resources/list':
      return rpcResult(id, { resources: [] })
    case 'resources/templates/list':
      return rpcResult(id, { resourceTemplates: [] })
    case 'prompts/list':
      return rpcResult(id, { prompts: [] })

    case 'tools/call': {
      const name = String((params as { name?: unknown }).name ?? '')
      const args = ((params as { arguments?: unknown }).arguments ?? {}) as Record<string, unknown>
      const tool = TOOLS_BY_NAME.get(name)

      if (!tool) {
        return rpcError(
          id,
          RPC.INVALID_PARAMS,
          `Unknown tool "${name}". Available: ${[...TOOLS_BY_NAME.keys()].join(', ')}.`,
        )
      }

      try {
        const payload = await tool.handler(args, ctx)
        return rpcResult(id, {
          content: [{ type: 'text', text: JSON.stringify(payload) }],
          isError: false,
        })
      } catch (error) {
        // A tool failing is data the model should act on, not a broken
        // connection: it comes back as a successful RPC carrying isError so
        // the model can fix its arguments and retry.
        const text =
          error instanceof ToolError
            ? error.message
            : `${name} failed: ${error instanceof Error ? error.message : String(error)}`
        console.error(`mcp tool ${name} failed`, error)
        return rpcResult(id, { content: [{ type: 'text', text }], isError: true })
      }
    }

    default:
      if (method.startsWith('notifications/')) return null // acknowledged, no reply
      if (id === null) return null // any other notification
      return rpcError(id, RPC.METHOD_NOT_FOUND, `Unsupported method "${method}".`)
  }
}

/*----------------------------------------------------------------------------
  The handler
----------------------------------------------------------------------------*/
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS })
  }

  // GET is how a client opens a server-initiated SSE stream. We are stateless
  // and never push, and the spec's prescribed answer for that is 405.
  if (req.method === 'GET') {
    return jsonResponse(
      {
        error: 'This MCP server is stateless and does not open SSE streams. POST JSON-RPC instead.',
        server: SERVER_NAME,
        version: SERVER_VERSION,
      },
      405,
      { Allow: 'POST, OPTIONS' },
    )
  }

  // No session to terminate, but succeeding is friendlier than erroring on a
  // client's tidy-up.
  if (req.method === 'DELETE') {
    return new Response(null, { status: 204, headers: CORS })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Use POST.' }, 405, { Allow: 'POST, OPTIONS' })
  }

  let caller: Awaited<ReturnType<typeof resolveCaller>>
  let db: Awaited<ReturnType<typeof callerClient>>
  try {
    const token = extractToken(req)
    if (!token) {
      throw new HttpError(
        401,
        'no_token',
        'No MCP token. Send it as `Authorization: Bearer <token>`, as the ' +
          '`x-mcp-token` header, or as `?token=` on the URL. Mint one in the ' +
          'portal under your account menu → Connect Claude.',
      )
    }
    caller = await resolveCaller(token)
    db = await callerClient(caller)
  } catch (error) {
    const err =
      error instanceof HttpError
        ? error
        : new HttpError(500, 'auth_failed', error instanceof Error ? error.message : String(error))
    if (err.status >= 500) console.error('mcp auth failed', error)
    return jsonResponse(
      { error: { code: err.code, message: err.message } },
      err.status,
      err.status === 401 ? { 'WWW-Authenticate': 'Bearer realm="christensen-rep-portal"' } : {},
    )
  }

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return jsonResponse(rpcError(null, RPC.PARSE_ERROR, 'Request body must be valid JSON.'), 400)
  }

  // Batching was dropped in protocol 2025-06-18, but older clients still send
  // arrays and handling one is three lines.
  const messages: RpcMessage[] = Array.isArray(body) ? (body as RpcMessage[]) : [body as RpcMessage]

  if (messages.length === 0 || messages.some((m) => typeof m !== 'object' || m === null)) {
    return jsonResponse(rpcError(null, RPC.INVALID_REQUEST, 'Expected a JSON-RPC message.'), 400)
  }

  const replies: unknown[] = []
  for (const message of messages) {
    try {
      const reply = await dispatch(message, { db, caller })
      if (reply !== null) replies.push(reply)
    } catch (error) {
      console.error('mcp dispatch failed', error)
      replies.push(
        rpcError(
          message.id ?? null,
          RPC.INTERNAL,
          error instanceof Error ? error.message : 'Internal error.',
        ),
      )
    }
  }

  // Notifications only: acknowledge with 202 and no body, as the spec requires.
  if (replies.length === 0) {
    return new Response(null, { status: 202, headers: CORS })
  }

  return jsonResponse(Array.isArray(body) ? replies : replies[0])
})
