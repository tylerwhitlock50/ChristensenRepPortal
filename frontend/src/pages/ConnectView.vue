<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useSessionStore } from '@/stores/session'
import { useMcpOrders } from '@/composables/useAppSettings'
import { hasDraftScope, rpcErrorText } from '@/lib/mcpOrders'
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

/**
 * Connect Claude — self-service credentials for the MCP endpoint.
 *
 * The whole page exists for one moment: `minted` is the only place the token
 * plaintext is ever visible, and it lives in component state that a reload
 * throws away. Everything else on the page is metadata about tokens whose
 * secrets are already unrecoverable.
 */
const session = useSessionStore()
const tokens = useMcpTokens()
const create = useCreateMcpToken()
const revoke = useRevokeMcpToken()

const name = ref('')
/**
 * Claude order drafting (feature.mcp_orders): offered only to users on its
 * allow-list. The server re-checks both when minting and on every call.
 */
const mcpOrders = useMcpOrders()
const draftOrders = ref(false)
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
    minted.value = await create.mutateAsync({
      name: name.value,
      draftOrders: mcpOrders.available.value && draftOrders.value,
    })
    name.value = ''
    draftOrders.value = false
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
        plain English — “which of my dealers are behind pace”, “what did Smoky
        Mountain buy last year”, “what’s on backorder for me”. Claude sees
        <strong class="text-ink">exactly the accounts you see in this portal</strong>,
        nothing more, and it cannot change anything.
        <template v-if="mcpOrders.available.value">
          The one exception is opt-in: a token can also let Claude
          <strong class="text-ink">draft orders</strong> for you to review and
          submit here. Claude never submits an order itself.
        </template>
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
          password: anyone holding it can read your account data.
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

        <p
          v-if="hasDraftScope(minted.scopes)"
          class="border-line border-l-accent text-ink-2 border border-l-[3px] p-3 text-sm"
        >
          <strong class="text-ink">This token can draft orders, so it only works from a header.</strong>
          Use the Claude Code command below, or put the token in an
          <code class="font-mono text-xs">Authorization: Bearer</code> header in
          Claude Desktop. Never paste it into a URL or a claude.ai connector: the
          portal refuses it there. If it ever ends up in a URL, revoke it.
        </p>

        <div v-if="!hasDraftScope(minted.scopes)">
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

    <AppCard title="Set it up">
      <div class="text-ink space-y-4 text-sm">
        <div>
          <p class="u-label text-muted mb-1">claude.ai (web or desktop)</p>
          <ol class="text-muted list-decimal space-y-1 pl-5">
            <li>Settings → Connectors → <strong class="text-ink">Add custom connector</strong>.</li>
            <li>Name it “Rep Portal” and paste the <strong class="text-ink">connector URL</strong> above
              (read-only tokens only: an order-drafting token is refused in a URL).</li>
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
        <label
          v-if="mcpOrders.available.value"
          class="flex w-full cursor-pointer items-start gap-3 pt-1"
        >
          <input v-model="draftOrders" type="checkbox" class="mt-0.5 size-5 shrink-0" />
          <span class="text-sm">
            <span class="text-ink block font-semibold">Let Claude draft orders</span>
            <span class="text-muted block">
              Claude can create, change and cancel order drafts; you review and
              submit each one here. Drafting needs the header setup — Claude
              Desktop or Claude Code with an Authorization header. A drafting
              token is refused in a connector URL, so no URL is shown for it. One
              drafting token at a time.
            </span>
          </span>
        </label>
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
                <AppBadge v-if="hasDraftScope(token.scopes)" tone="high">Drafts orders</AppBadge>
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
