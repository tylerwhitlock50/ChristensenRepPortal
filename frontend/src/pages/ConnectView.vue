<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useSessionStore } from '@/stores/session'
import { useMcpOrders } from '@/composables/useAppSettings'
import { rpcErrorText } from '@/lib/mcpOrders'
import { shortDate, daysAgo } from '@/lib/format'
import {
  MCP_URL,
  claudeCodeCommand,
  connectorUrl,
  isLive,
  useCreateMcpToken,
  useMcpTokens,
  useRevokeMcpToken,
  type McpTokenRow,
  type MintedToken,
} from '@/composables/useMcpTokens'
import {
  claudeCodeOAuthCommand,
  useDisconnectMcpApp,
  useMcpConnectedApps,
  type McpConnectedApp,
} from '@/composables/useMcpOAuth'

/**
 * Connect Claude — how a person points Claude at the MCP endpoint.
 *
 * Two ways, in this order:
 *
 *   Sign-in (OAuth, migration 20261116120000). One address for everyone,
 *   with nothing secret in it. Claude sends the person to /oauth/consent,
 *   they approve, and from then on Claude holds its own credential. This
 *   page only shows the address and lists what has been connected.
 *
 *   Tokens, the older way. `minted` is the only place a token's plaintext is
 *   ever visible, and it lives in component state that a reload throws away.
 *   Everything else in that section is metadata about tokens whose secrets
 *   are already unrecoverable. Kept because connectors set up with one still
 *   work, and for a project whose OAuth server is not switched on.
 */
const session = useSessionStore()
const tokens = useMcpTokens()
const create = useCreateMcpToken()
const revoke = useRevokeMcpToken()
const apps = useMcpConnectedApps()
const disconnect = useDisconnectMcpApp()

/**
 * Sign-in is offered once Supabase Auth says its OAuth server is on. While
 * that answer is loading, or the check failed, tokens stay the page's lead:
 * better to show the way that certainly works than promise one that may not.
 */
const oauthOn = computed(() => apps.data.value?.enabled === true)
const oauthOff = computed(() => apps.data.value?.enabled === false)
const connectedApps = computed(() => apps.data.value?.apps ?? [])
const confirmingDisconnect = ref<string | null>(null)
const disconnectError = ref('')

async function doDisconnect(app: McpConnectedApp) {
  disconnectError.value = ''
  try {
    await disconnect.mutateAsync(app.clientId)
    confirmingDisconnect.value = null
  } catch (e) {
    disconnectError.value = (e as Error).message || 'Could not disconnect that app.'
  }
}

const name = ref('')
/**
 * Claude order drafting (feature.mcp_orders): follows the USER, not the
 * token. Flag on + a row in mcp_order_users and every token this user holds
 * (header or connector URL) gets the order tools; mcp_orders_gate() re-checks
 * on every call. Nothing to pick when minting, so this only drives one line
 * of copy.
 */
const mcpOrders = useMcpOrders()
const minted = ref<MintedToken | null>(null)
const copied = ref<string | null>(null)
const confirmingRevoke = ref<string | null>(null)

const live = computed(() => (tokens.data.value ?? []).filter(isLive))
const past = computed(() => (tokens.data.value ?? []).filter((t) => !isLive(t)))
const atLimit = computed(() => live.value.length >= 5)

async function copy(value: string, label: string) {
  try {
    await navigator.clipboard.writeText(value)
  } catch {
    // Safari without a user gesture, or an insecure origin. Selecting the
    // text is a worse experience than the clipboard but better than nothing.
    const field = document.createElement('textarea')
    field.value = value
    document.body.appendChild(field)
    field.select()
    document.execCommand('copy')
    field.remove()
  }
  copied.value = label
  setTimeout(() => {
    if (copied.value === label) copied.value = null
  }, 2000)
}

/* One error line for both writes. Caught here rather than read off the
   mutations' `error` refs: an unhandled mutateAsync rejection climbs to
   App.vue's boundary and replaces the whole page with "This screen didn't
   load" — for a refused token name. */
const actionError = ref('')

async function mint() {
  actionError.value = ''
  minted.value = null
  try {
    minted.value = await create.mutateAsync({ name: name.value })
    name.value = ''
  } catch (e) {
    actionError.value = rpcErrorText((e as Error).message) || 'Could not create that token.'
  }
}

async function doRevoke(token: McpTokenRow) {
  actionError.value = ''
  try {
    await revoke.mutateAsync(token.id)
    confirmingRevoke.value = null
    if (minted.value?.id === token.id) minted.value = null
  } catch (e) {
    actionError.value = (e as Error).message || 'Could not revoke that token.'
  }
}
</script>

<template>
  <div class="space-y-4">
    <header>
      <h1 class="font-display text-ink text-xl font-bold tracking-[0.06em] uppercase">
        Connect Claude
      </h1>
      <p class="text-muted mt-1 max-w-2xl text-sm">
        Give Claude read-only access to your accounts so you can ask questions in
        plain English — “which of my dealers are behind pace”, “what did Smith
        Outdoors buy last year”, “what’s on backorder for me”. Claude sees
        <strong class="text-ink">exactly the accounts you see in this portal</strong>,
        nothing more<template v-if="!mcpOrders.available.value">, and it cannot change anything</template>.
      </p>
      <p v-if="mcpOrders.available.value" class="text-ink-2 mt-2 max-w-2xl text-sm">
        Your Claude connection can also <strong class="text-ink">draft orders</strong>
        — never submit them. You review and submit each one here in the portal.
      </p>
    </header>

    <!-- Sign-in: the way to connect from now on. -->
    <AppCard v-if="oauthOn" title="Connect by signing in">
      <div class="text-ink space-y-4 text-sm">
        <div>
          <p class="u-label text-muted mb-1">Connector address — the same for everyone</p>
          <div class="flex flex-wrap items-center gap-2">
            <code
              class="border-line bg-canvas text-ink min-w-0 flex-1 overflow-x-auto border px-2 py-2 font-mono text-xs"
            >{{ MCP_URL }}</code>
            <AppButton @click="copy(MCP_URL, 'oauth-url')">
              {{ copied === 'oauth-url' ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
          <p class="text-muted mt-1.5 text-xs">
            There is nothing secret in it. It is safe to share with the team.
          </p>
        </div>

        <div>
          <p class="u-label text-muted mb-1">Claude (web, desktop or phone)</p>
          <ol class="text-muted list-decimal space-y-1 pl-5">
            <li>
              In Claude, open Connectors and add a
              <strong class="text-ink">custom connector</strong> with this address. On a
              Team or Enterprise plan an owner adds it once for the whole
              organization, and you only press <strong class="text-ink">Connect</strong>.
            </li>
            <li>
              Claude opens this portal and asks you to approve. Sign in if
              asked, check it says Claude, and press
              <strong class="text-ink">Approve</strong>.
            </li>
            <li>Start a chat and ask something about your accounts.</li>
          </ol>
        </div>

        <div>
          <p class="u-label text-muted mb-1">Claude Code</p>
          <div class="flex flex-wrap items-center gap-2">
            <code
              class="border-line bg-canvas text-ink min-w-0 flex-1 overflow-x-auto border px-2 py-2 font-mono text-xs"
            >{{ claudeCodeOAuthCommand(MCP_URL) }}</code>
            <AppButton @click="copy(claudeCodeOAuthCommand(MCP_URL), 'oauth-cli')">
              {{ copied === 'oauth-cli' ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
          <p class="text-muted mt-1.5">
            Then type <code class="font-mono text-xs">/mcp</code> in Claude Code, pick
            <code class="font-mono text-xs">rep-portal</code> and sign in.
          </p>
        </div>
      </div>
    </AppCard>

    <AppCard
      v-if="oauthOn"
      title="Connected apps"
      :hint="`${connectedApps.length} connected`"
    >
      <p v-if="disconnectError" role="alert" class="text-danger mb-3 text-sm">
        {{ disconnectError }}
      </p>
      <AsyncState
        :loading="apps.isLoading.value"
        :error="apps.error.value"
        :has-data="apps.data.value !== undefined"
        :updated-at="apps.dataUpdatedAt.value"
        :empty="connectedApps.length === 0"
        empty-title="Nothing connected yet"
        empty-body="Once you approve Claude it shows up here, and this is where you disconnect it."
        @retry="apps.refetch()"
      >
        <ul class="divide-line divide-y">
          <li
            v-for="app in connectedApps"
            :key="app.clientId"
            class="flex flex-wrap items-center justify-between gap-3 py-3"
          >
            <div class="min-w-0">
              <p class="text-ink text-sm font-semibold">{{ app.name }}</p>
              <p class="text-muted mt-0.5 text-xs">
                Connected {{ shortDate(app.grantedAt) }} ·
                <template v-if="app.lastUsedAt">last used {{ daysAgo(app.lastUsedAt) }}</template>
                <template v-else>not used yet</template>
              </p>
            </div>

            <!-- Not while viewing as a rep: the apps listed are the real
                 user's, as the tokens below are. -->
            <div v-if="session.canWrite" class="flex items-center gap-2">
              <template v-if="confirmingDisconnect === app.clientId">
                <span class="text-muted text-xs">Disconnect it?</span>
                <AppButton
                  variant="danger"
                  :loading="disconnect.isPending.value"
                  @click="doDisconnect(app)"
                >
                  Disconnect
                </AppButton>
                <AppButton variant="ghost" @click="confirmingDisconnect = null">Cancel</AppButton>
              </template>
              <AppButton v-else variant="ghost" @click="confirmingDisconnect = app.clientId">
                Disconnect
              </AppButton>
            </div>
          </li>
        </ul>
      </AsyncState>

      <template #footer>
        <p class="text-muted text-xs">
          Disconnecting takes effect immediately: the app’s next request is
          refused, and it has to ask you again. Apps also stop working the
          moment an admin deactivates your portal account.
        </p>
      </template>
    </AppCard>

    <!-- Tokens: the older way. A heading of its own once sign-in exists, so
         nobody reads the token form as the first step. -->
    <header v-if="oauthOn" class="pt-2">
      <h2 class="font-display text-ink text-base font-bold tracking-[0.06em] uppercase">
        Tokens — the older way
      </h2>
      <p class="text-muted mt-1 max-w-2xl text-sm">
        Before sign-in, a connection carried a token in its address. Those
        connections keep working. For anything new, sign in instead: a token
        in a connector address is a password in a link.
      </p>
    </header>

    <!-- The one-time reveal. Rendered above the list so it cannot be missed. -->
    <AppCard v-if="minted" title="Your new token">
      <div class="border-accent bg-canvas border-l-4 p-3">
        <p class="text-ink text-sm font-semibold">
          Copy this now — it is shown once and cannot be recovered.
        </p>
        <p class="text-muted mt-1 text-xs">
          If you lose it, revoke it below and create another. Treat it like your
          password: anyone holding it (or the connector URL) can read your
          account data<template v-if="mcpOrders.available.value"> and draft
          orders as you — never submit them</template>.
        </p>
      </div>

      <div class="mt-4 space-y-4">
        <div>
          <p class="u-label text-muted mb-1">Token</p>
          <div class="flex flex-wrap items-center gap-2">
            <code
              class="border-line bg-canvas text-ink min-w-0 flex-1 overflow-x-auto border px-2 py-2 font-mono text-xs"
            >{{ minted.token }}</code>
            <AppButton @click="copy(minted.token, 'token')">
              {{ copied === 'token' ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
        </div>

        <div>
          <p class="u-label text-muted mb-1">Connector URL — for claude.ai</p>
          <div class="flex flex-wrap items-center gap-2">
            <code
              class="border-line bg-canvas text-ink min-w-0 flex-1 overflow-x-auto border px-2 py-2 font-mono text-xs"
            >{{ connectorUrl(minted.token) }}</code>
            <AppButton @click="copy(connectorUrl(minted.token), 'url')">
              {{ copied === 'url' ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
        </div>

        <div>
          <p class="u-label text-muted mb-1">Claude Code — one command</p>
          <div class="flex flex-wrap items-center gap-2">
            <code
              class="border-line bg-canvas text-ink min-w-0 flex-1 overflow-x-auto border px-2 py-2 font-mono text-xs"
            >{{ claudeCodeCommand(minted.token) }}</code>
            <AppButton @click="copy(claudeCodeCommand(minted.token), 'cli')">
              {{ copied === 'cli' ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
        </div>
      </div>

      <template #footer>
        <AppButton variant="ghost" @click="minted = null">
          I’ve saved it — hide
        </AppButton>
      </template>
    </AppCard>

    <AppCard :title="oauthOn ? 'Set up with a token' : 'Set it up'">
      <div class="text-ink space-y-4 text-sm">
        <p v-if="oauthOff" class="border-line bg-canvas border-l-accent border border-l-[3px] px-3 py-2.5">
          Connecting by signing in (one address for the whole team, no token)
          is not switched on for this portal yet. Until an admin turns it on,
          connect with a token as below.
        </p>
        <div>
          <p class="u-label text-muted mb-1">claude.ai (web or desktop)</p>
          <ol class="text-muted list-decimal space-y-1 pl-5">
            <li>Settings → Connectors → <strong class="text-ink">Add custom connector</strong>.</li>
            <li>Name it “Rep Portal” and paste the <strong class="text-ink">connector URL</strong> above.</li>
            <li>Add it, then start a chat and ask something about your accounts.</li>
          </ol>
        </div>
        <div>
          <p class="u-label text-muted mb-1">Claude Code</p>
          <p class="text-muted">
            Run the command above in a terminal. It sends the token as a header
            rather than in the URL, which is the safer of the two — prefer it
            wherever your client supports custom headers.
          </p>
        </div>
        <div>
          <p class="u-label text-muted mb-1">Endpoint</p>
          <code class="border-line bg-canvas text-ink block overflow-x-auto border px-2 py-2 font-mono text-xs">{{ MCP_URL }}</code>
        </div>
      </div>
    </AppCard>

    <AppCard title="Your tokens" :hint="`${live.length} active`">
      <!-- Not offered while viewing as a rep. A token is a credential, and
           the tokens listed below are the REAL user's — minting from here
           would mint one for the admin while the page reads as the rep's. -->
      <div
        v-if="session.canWrite"
        class="border-line mb-4 flex flex-wrap items-end gap-3 border-b pb-4"
      >
        <label class="min-w-48 flex-1">
          <span class="u-label text-muted mb-1 block">Name this token</span>
          <input
            v-model="name"
            type="text"
            maxlength="60"
            placeholder="Claude on my laptop"
            class="border-line bg-surface text-ink min-h-12 w-full border px-3 text-[15px]"
            @keyup.enter="!atLimit && mint()"
          />
        </label>
        <AppButton
          variant="primary"
          :loading="create.isPending.value"
          :disabled="atLimit"
          @click="mint()"
        >
          Create token
        </AppButton>
      </div>

      <p v-if="atLimit" class="text-muted mb-3 text-sm">
        You have five active tokens, which is the limit. Revoke one you no longer
        use to make room.
      </p>
      <p v-if="actionError" role="alert" class="text-danger mb-3 text-sm">
        {{ actionError }}
      </p>

      <AsyncState
        :loading="tokens.isLoading.value"
        :error="tokens.error.value"
        :has-data="tokens.data.value !== undefined"
        :updated-at="tokens.dataUpdatedAt.value"
        :empty="(tokens.data.value ?? []).length === 0"
        empty-title="No tokens yet"
        empty-body="Create one above to connect Claude."
        @retry="tokens.refetch()"
      >
        <ul class="divide-line divide-y">
          <li
            v-for="token in [...live, ...past]"
            :key="token.id"
            class="flex flex-wrap items-center justify-between gap-3 py-3"
          >
            <div class="min-w-0">
              <p class="text-ink flex flex-wrap items-center gap-2 text-sm font-semibold">
                {{ token.name }}
                <AppBadge v-if="token.revoked_at" tone="neutral">Revoked</AppBadge>
                <AppBadge v-else-if="!isLive(token)" tone="neutral">Expired</AppBadge>
              </p>
              <p class="text-muted mt-0.5 font-mono text-xs">{{ token.token_prefix }}…</p>
              <p class="text-muted mt-0.5 text-xs">
                Created {{ shortDate(token.created_at) }} ·
                <template v-if="token.revoked_at">
                  revoked {{ shortDate(token.revoked_at) }}
                </template>
                <template v-else>expires {{ shortDate(token.expires_at) }}</template>
                ·
                <template v-if="token.last_used_at">
                  last used {{ daysAgo(token.last_used_at) }}
                </template>
                <template v-else>never used</template>
              </p>
            </div>

            <div v-if="isLive(token)" class="flex items-center gap-2">
              <template v-if="confirmingRevoke === token.id">
                <span class="text-muted text-xs">Revoke for good?</span>
                <AppButton
                  variant="danger"
                  :loading="revoke.isPending.value"
                  @click="doRevoke(token)"
                >
                  Revoke
                </AppButton>
                <AppButton variant="ghost" @click="confirmingRevoke = null">Cancel</AppButton>
              </template>
              <AppButton v-else variant="ghost" @click="confirmingRevoke = token.id">
                Revoke
              </AppButton>
            </div>
          </li>
        </ul>
      </AsyncState>

      <template #footer>
        <p class="text-muted text-xs">
          Revoking takes effect immediately — the next request from that client
          is refused. Tokens also stop working the moment an admin deactivates
          your portal account.
        </p>
      </template>
    </AppCard>
  </div>
</template>
