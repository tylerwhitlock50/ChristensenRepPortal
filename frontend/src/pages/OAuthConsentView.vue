<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import type { OAuthAuthorizationDetails } from '@supabase/supabase-js'
import AppButton from '@/components/ui/AppButton.vue'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'
import { useMcpOrders } from '@/composables/useAppSettings'
import {
  classifyRedirect,
  describeScopes,
  isAuthorizationId,
  parseAllowedRedirects,
  sameRedirectTarget,
} from '@/lib/oauthConsent'

/**
 * "Connect Claude to the Rep Portal?" — the consent screen of the OAuth flow
 * (migration 20261116120000, supabase/functions/mcp/README.md).
 *
 * Nobody navigates here. Supabase Auth sends the browser to
 * /oauth/consent?authorization_id=… when an app (Claude) starts connecting,
 * and waits for this page to say yes or no on the signed-in person's behalf.
 * The router's ordinary guard has already sent a signed-out visitor through
 * /login and back, with the query intact.
 *
 * Two things about the Auth API shape this page:
 *
 *  - Reading the request is not free of effect. The first read ties the
 *    request to the signed-in user, and if that user has approved this app
 *    before, Auth approves again on the spot and answers with a redirect
 *    instead of the details. So it is read once, on mount, never on a timer
 *    or a refetch.
 *  - The app's name is whatever its registrant typed. The redirect URI is
 *    the only part Auth verifies, so that is what decides whether Approve is
 *    offered at all (lib/oauthConsent.ts).
 */
const route = useRoute()
const session = useSessionStore()
const mcpOrders = useMcpOrders()

const allowedRedirects = parseAllowedRedirects(import.meta.env.VITE_MCP_OAUTH_REDIRECTS)

type Phase =
  | 'loading'
  | 'missing' // opened without a request to approve
  | 'unavailable' // the request is gone: expired, used, or someone else's
  | 'consent'
  | 'leaving' // on the way back to the app
  | 'refused' // said no to an app we would not send anyone back to
  | 'blocked' // approved before, but the address it would go to is not one we send people to

const phase = ref<Phase>('loading')
const details = ref<OAuthAuthorizationDetails | null>(null)
const problem = ref('')
const busy = ref<'approve' | 'deny' | null>(null)
const blockedHost = ref('')

const authorizationId = computed(() => {
  const raw = route.query.authorization_id
  return isAuthorizationId(raw) ? raw : null
})

const redirect = computed(() =>
  classifyRedirect(details.value?.redirect_uri ?? '', allowedRedirects),
)
const appName = computed(() => details.value?.client.name?.trim() || 'An app')
const scopeLines = computed(() => describeScopes(details.value?.scope))

/** Approving here would connect the admin's own account while the page
 *  reads as the rep's. Same rule as minting a token on /connect. */
const canApprove = computed(
  () => redirect.value.trust !== 'unknown' && !session.isViewingAs && !session.isOffline,
)

function leave(url: string) {
  phase.value = 'leaving'
  window.location.assign(url)
}

function explain(message: string | undefined): string {
  const text = message ?? ''
  if (/not found|cannot be processed|expired/i.test(text)) {
    return 'This connection request has expired or was already answered. Go back to Claude and connect again.'
  }
  if (/oauth.*(disabled|not enabled)|not enabled/i.test(text)) {
    return 'Signing in from Claude is not switched on for this portal yet. Ask your admin.'
  }
  return text || 'The connection request could not be loaded. Go back to Claude and try again.'
}

onMounted(async () => {
  if (!authorizationId.value) {
    phase.value = 'missing'
    return
  }
  const { data, error } = await supabase.auth.oauth.getAuthorizationDetails(authorizationId.value)
  if (error || !data) {
    problem.value = explain(error?.message)
    phase.value = 'unavailable'
    return
  }
  if ('authorization_id' in data) {
    details.value = data
    phase.value = 'consent'
    return
  }
  // Approved before: Auth has already said yes and only the trip back is
  // left. Still not to an address this page would refuse to offer.
  const back = classifyRedirect(data.redirect_url, allowedRedirects)
  if (back.trust === 'unknown') {
    blockedHost.value = back.host
    phase.value = 'blocked'
    return
  }
  leave(data.redirect_url)
})

async function decide(action: 'approve' | 'deny') {
  const id = authorizationId.value
  const shown = details.value
  if (!id || !shown || busy.value) return
  if (action === 'approve' && !canApprove.value) return

  busy.value = action
  problem.value = ''
  try {
    const { data, error } =
      action === 'approve'
        ? await supabase.auth.oauth.approveAuthorization(id, { skipBrowserRedirect: true })
        : await supabase.auth.oauth.denyAuthorization(id, { skipBrowserRedirect: true })
    if (error || !data?.redirect_url) {
      problem.value = explain(error?.message)
      return
    }
    // A refusal normally travels back to the app so it can say "denied".
    // Not to an address this page would not approve: the request is closed
    // on the server, and the person stays here.
    if (redirect.value.trust === 'unknown') {
      phase.value = 'refused'
      return
    }
    // Go only where the person was told they would go.
    if (!sameRedirectTarget(data.redirect_url, shown.redirect_uri)) {
      problem.value =
        'The reply would have gone somewhere other than the address shown above, so it was not sent. Go back to Claude and try again.'
      return
    }
    leave(data.redirect_url)
  } catch (e) {
    problem.value = (e as Error).message || 'That did not go through. Try again.'
  } finally {
    busy.value = null
  }
}
</script>

<template>
  <div class="bg-canvas text-ink flex min-h-svh justify-center px-5 py-10">
    <div class="flex w-full max-w-md flex-col">
      <span class="font-label text-accent text-xs font-semibold tracking-[0.24em] uppercase">
        Christensen Arms · Rep Portal
      </span>

      <!-- Loading, and the moment between the answer and the app. -->
      <div v-if="phase === 'loading' || phase === 'leaving'" class="mt-6" role="status">
        <h1 class="u-display text-3xl leading-tight">
          {{ phase === 'leaving' ? 'Sending you back' : 'One moment' }}
        </h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          {{
            phase === 'leaving'
              ? 'You can close this tab if it does not close by itself.'
              : 'Checking the connection request.'
          }}
        </p>
      </div>

      <div v-else-if="phase === 'missing'" class="mt-6">
        <h1 class="u-display text-3xl leading-tight">Nothing to approve</h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          This page opens by itself when you connect Claude to the portal. To
          start, add the portal as a connector in Claude.
        </p>
        <RouterLink :to="{ name: 'connect' }" class="mt-6 inline-block">
          <AppButton variant="secondary">How to connect Claude</AppButton>
        </RouterLink>
      </div>

      <div v-else-if="phase === 'unavailable'" class="mt-6">
        <h1 class="u-display text-3xl leading-tight">This request can’t be used</h1>
        <p role="alert" class="text-ink-2 mt-3 text-[15px] leading-relaxed">{{ problem }}</p>
        <RouterLink :to="{ name: 'connect' }" class="mt-6 inline-block">
          <AppButton variant="secondary">Connect Claude</AppButton>
        </RouterLink>
      </div>

      <div v-else-if="phase === 'refused'" class="mt-6" role="status">
        <h1 class="u-display text-3xl leading-tight">Refused</h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          Nothing was connected and nothing was sent. You can close this tab.
        </p>
      </div>

      <div v-else-if="phase === 'blocked'" class="mt-6">
        <h1 class="u-display text-3xl leading-tight">Not sent</h1>
        <p role="alert" class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          An app you approved before asked to connect again, and its reply
          address
          <template v-if="blockedHost">
            (<strong class="text-ink font-mono text-sm">{{ blockedHost }}</strong>)
          </template>
          is not Claude’s. Nothing was sent to it. If you do not recognise it,
          disconnect it under Connect Claude and tell your admin.
        </p>
        <RouterLink :to="{ name: 'connect' }" class="mt-6 inline-block">
          <AppButton variant="secondary">Review connected apps</AppButton>
        </RouterLink>
      </div>

      <!-- The decision. -->
      <div v-else-if="details" class="mt-6">
        <h1 class="u-display text-3xl leading-tight">
          Connect {{ appName }} to your portal account?
        </h1>

        <dl class="border-line bg-surface mt-6 border text-sm">
          <div class="border-line border-b px-4 py-3">
            <dt class="u-label text-muted">Signed in as</dt>
            <dd class="text-ink mt-1 font-semibold">{{ session.displayName }}</dd>
            <dd v-if="session.user?.email" class="text-muted">{{ session.user.email }}</dd>
          </div>
          <div class="px-4 py-3">
            <dt class="u-label text-muted">Access goes to</dt>
            <dd class="mt-1">
              <template v-if="redirect.trust === 'claude'">
                <span class="text-ink font-semibold">Claude</span>
                <span class="text-muted font-mono text-xs"> · {{ redirect.host }}</span>
              </template>
              <template v-else-if="redirect.trust === 'this_device'">
                <span class="text-ink font-semibold">An app on this computer</span>
                <span class="text-muted font-mono text-xs"> · {{ redirect.host }}</span>
              </template>
              <template v-else>
                <span class="text-ink font-mono text-sm font-semibold">
                  {{ redirect.host || 'an unreadable address' }}
                </span>
              </template>
            </dd>
          </div>
        </dl>

        <p
          v-if="redirect.trust === 'this_device'"
          class="border-line bg-surface border-l-accent mt-3 border border-l-[3px] px-3 py-2.5 text-sm"
        >
          Approve this only if you started it yourself a moment ago, from
          Claude Code or another app on this computer.
        </p>

        <template v-if="redirect.trust === 'unknown'">
          <p
            role="alert"
            class="border-line bg-surface border-l-accent mt-3 border border-l-[3px] px-3 py-2.5 text-sm"
          >
            <strong class="text-ink">This request can’t be approved.</strong>
            It calls itself “{{ appName }}”, but its reply would go to the
            address above, which is not Claude’s and not one this portal sends
            access to. If someone sent you a link that brought you here, do not
            use it again, and tell your admin.
          </p>
        </template>

        <template v-else>
          <h2 class="u-label text-ink mt-6">What it will be able to do</h2>
          <ul class="text-ink-2 mt-2 list-disc space-y-1.5 pl-5 text-[15px] leading-relaxed">
            <li>
              Read your accounts, orders, shipments, stock and goals:
              <strong class="text-ink">exactly what you see in this portal</strong>, nothing more.
            </li>
            <li v-if="mcpOrders.available.value">
              <strong class="text-ink">Draft orders</strong> for you to review. It can never
              submit one; you do that here in the portal.
            </li>
            <li v-if="!mcpOrders.available.value">It cannot change anything.</li>
            <li v-else>It cannot change anything else.</li>
          </ul>

          <template v-if="scopeLines.length">
            <h2 class="u-label text-ink mt-5">Also shared with it</h2>
            <ul class="text-ink-2 mt-2 list-disc space-y-1.5 pl-5 text-[15px] leading-relaxed">
              <li v-for="line in scopeLines" :key="line">{{ line }}</li>
            </ul>
          </template>
        </template>

        <p v-if="session.isViewingAs" role="alert" class="text-danger mt-5 text-sm">
          You are viewing the portal as someone else. Leave that view first:
          approving here would connect your own account, not theirs.
        </p>
        <p v-else-if="session.isOffline" role="alert" class="text-danger mt-5 text-sm">
          You are offline. Reconnect, then go back to Claude and try again.
        </p>
        <p v-if="problem" role="alert" class="text-danger mt-5 text-sm">{{ problem }}</p>

        <div class="mt-6 flex flex-col gap-2">
          <AppButton
            v-if="redirect.trust !== 'unknown'"
            variant="primary"
            size="lg"
            block
            :loading="busy === 'approve'"
            :disabled="!canApprove || busy !== null"
            @click="decide('approve')"
          >
            Approve
          </AppButton>
          <AppButton
            variant="secondary"
            block
            :loading="busy === 'deny'"
            :disabled="busy !== null"
            @click="decide('deny')"
          >
            {{ redirect.trust === 'unknown' ? 'Refuse and close' : 'Deny' }}
          </AppButton>
        </div>

        <p v-if="redirect.trust !== 'unknown'" class="text-muted mt-5 text-xs leading-relaxed">
          You can disconnect it at any time under your account menu → Connect
          Claude. Not {{ session.displayName }}? Deny, sign out of the portal,
          and connect again from Claude.
        </p>
      </div>

      <div class="border-line mt-auto flex items-center gap-2.5 border-t pt-4">
        <span class="bg-accent block h-4 w-[3px]" aria-hidden="true" />
        <span class="font-label text-muted text-xs font-semibold tracking-[0.16em] uppercase">
          Rep Portal · Field Sales
        </span>
      </div>
    </div>
  </div>
</template>
