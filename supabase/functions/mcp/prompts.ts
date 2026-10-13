/*============================================================================
  mcp/prompts.ts — MCP prompts: the three questions reps actually bring to
  Claude, as ready-made starting points (prompts/list, prompts/get).

  A prompt here is only a well-aimed user message: it names the tools that
  answer the question and the house rules for the answer. It reads nothing
  itself, so it needs no access rules — every number still comes from the
  tools, under the rep's own RLS.

  Voice (CEO direction, same as ai-brief/prompts.ts): the assistant is an
  analyst beside the rep, not a manager. Each prompt asks for observations
  and topics, never a task list.
============================================================================*/

export interface PromptArgument {
  name: string
  description: string
  required?: boolean
}

export interface PromptDef {
  name: string
  title: string
  description: string
  arguments: PromptArgument[]
  render: (args: Record<string, string>) => string
}

/** A thrown PromptError becomes a JSON-RPC invalid-params reply. */
export class PromptError extends Error {}

const HOUSE_RULES = `
How to answer:
- Invoiced revenue is "sales". Open order value is booked but not shipped;
  backlog is the unshipped part. Never mix them up.
- Round money ($48,000, not $47,983.42). Give dates ("no order since July 2")
  rather than counts of days.
- Observations and topics worth raising, never instructions: "their Mesa
  reorder is due and in stock", not "sell them a Mesa". I decide what to do.
- Use only what the tools return. If something is missing, leave it out.
- Keep it short enough to read on a phone in a parking lot.`.trim()

const PROMPTS: PromptDef[] = [
  {
    name: 'pre_call_brief',
    title: 'Pre-call brief',
    description:
      'A short brief before calling or walking into one dealer: trend, how they ' +
      'buy, what they are owed, what is in stock for them, and who to ask for.',
    arguments: [
      { name: 'account', description: 'Account name or customer key.', required: true },
    ],
    render: ({ account }) => `I'm about to call or visit ${account}. Brief me.

Use the Rep Portal tools: resolve the account with search_accounts unless I
gave a customer key, then get_account, get_account_revenue_trend,
get_account_sku_sales, list_backlog for that account, get_account_sku_gaps
and list_contacts. Check list_account_activity for the last notes and visit.

Cover, briefly:
1. Who they are and how this year compares with the same time last year.
2. How they buy — how often, typical order size, what they buy most.
3. What they are owed: open orders, anything past its promise date.
4. What is in stock for them: things they have bought before, and things
   other dealers carry that they don't.
5. Who to ask for (list_contacts' best_contact) — not the billing contact.

${HOUSE_RULES}`,
  },
  {
    name: 'plan_my_week',
    title: 'Plan my week',
    description:
      'Which accounts in my book look worth a call or visit this week, and the ' +
      'one fact that makes each worth the time.',
    arguments: [
      {
        name: 'focus',
        description: 'Optional: a state, city or region to keep the list near, e.g. "MT".',
      },
    ],
    render: ({ focus }) => `Help me plan my week${focus ? `, around ${focus}` : ''}.

Use the Rep Portal tools: whoami first (note data_through), then
get_territory_summary, list_territory_accounts (accounts down on last year,
gone quiet, or with large open orders), get_goal_progress for the accounts
furthest behind pace, and list_backlog for lines past their promise date.
${focus ? `Keep to accounts in or near ${focus} (search_accounts can filter by state).\n` : ''}
Then give me a short list — eight to twelve accounts — grouped by area so a
day of visits makes geographic sense. For each: the account, where it is,
and the one fact from the data that makes it worth the time this week.
Finish with anything territory-wide worth knowing before Monday.

${HOUSE_RULES}`,
  },
  {
    name: 'sell_from_stock',
    title: "What can I sell from today's stock",
    description:
      'Pitches from what is in stock today: products with stock and the dealers ' +
      'in my book they fit, or — for one account — what to offer them.',
    arguments: [
      {
        name: 'account',
        description: 'Optional: one account name or customer key to focus on.',
      },
    ],
    render: ({ account }) =>
      account
        ? `What can I offer ${account} from today's stock?

Use the Rep Portal tools: resolve the account with search_accounts unless I
gave a customer key, then get_account_sku_sales (what they buy), and
get_account_sku_gaps (in-stock products other dealers carry that they don't,
or haven't bought in a while). Confirm stock with check_availability.

Give me a short list of pitches: the product, how many are available, and
the fact from their own history or from other dealers that makes it a fit.
Company-wide figures are units and dealer counts only.

${HOUSE_RULES}`
        : `What can I sell from today's stock?

Use the Rep Portal tools: check_availability with available_only for what is
in stock, get_sku_sales for what sells in my territory, then
find_dealers_for_sku for the strongest few in-stock products to see which
dealers in my book have bought them (or the same family and chambering).

Give me a short list of pitches: the product, how many are available, and
the two or three dealers it fits best, with the fact behind each — when
they last bought it and how many. Company-wide figures are units and dealer
counts only.

${HOUSE_RULES}`,
  },
]

const BY_NAME = new Map(PROMPTS.map((p) => [p.name, p]))

/** The wire form for prompts/list. */
export function listPrompts() {
  return PROMPTS.map(({ name, title, description, arguments: args }) => ({
    name,
    title,
    description,
    arguments: args,
  }))
}

/** prompts/get: the rendered user message, or a PromptError. */
export function getPrompt(name: string, rawArgs: Record<string, unknown> | undefined) {
  const prompt = BY_NAME.get(name)
  if (!prompt) {
    throw new PromptError(
      `Unknown prompt "${name}". Available: ${PROMPTS.map((p) => p.name).join(', ')}.`,
    )
  }
  const args: Record<string, string> = {}
  for (const a of prompt.arguments) {
    const v = rawArgs?.[a.name]
    const text = typeof v === 'string' ? v.trim().slice(0, 200) : ''
    if (a.required && !text) throw new PromptError(`Prompt "${name}" needs \`${a.name}\`.`)
    if (text) args[a.name] = text
  }
  return {
    description: prompt.description,
    messages: [{ role: 'user', content: { type: 'text', text: prompt.render(args) } }],
  }
}
