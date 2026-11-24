<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import AppButton from '@/components/ui/AppButton.vue'
import { useSessionStore } from '@/stores/session'
import { useLegalDocuments } from '@/composables/useLegal'
import { renderMarkdown } from '@/lib/markdown'
import { shortDate } from '@/lib/format'
import {
  documentsToAgree,
  isUpdatedSinceAgreed,
  LEGAL_DOC_LABEL,
  LEGAL_DOC_ROUTE,
  legalErrorMessage,
  safeRedirect,
  type LegalDocKey,
  type LegalDocument,
} from '@/lib/legal'

/**
 * The click-wrap: the Terms of Use and the Privacy Policy, in full, and a box
 * to tick for each (migration 20261124090000, lib/legal.ts).
 *
 * Nobody navigates here on purpose. The router guard sends every signed-in
 * page here until the person has agreed to the current version of both,
 * carrying the page they asked for in ?redirect=, and useLegalGate() does
 * the same for a screen already open when a new version is published. On
 * "Agree and continue" the database records who agreed to which version
 * (by id and hash), when, and from where; then the page they asked for
 * opens. Declining signs them out.
 *
 * What is shown is exactly what is agreed to: the ids sent are the ids of
 * the documents on screen, and the database refuses any that is no longer
 * the current version (someone published while this was open), in which
 * case the screen reloads the text and asks again.
 */
const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const docs = useLegalDocuments({ forAgreement: true })

/**
 * Ticks belong to a VERSION (its legal_documents id), never to "the terms":
 * a version that replaces the one on screen arrives unticked, so nothing is
 * agreed to that was not shown when the box was ticked.
 */
const checked = ref<Record<number, boolean>>({})
const busy = ref<'agree' | 'decline' | 'retry' | null>(null)
const problem = ref('')

const destination = computed(() => safeRedirect(route.query.redirect))

const hasDocs = computed(() => docs.data.value !== undefined)
const current = computed<LegalDocument[]>(() => docs.data.value ?? [])
const outstanding = computed(() => documentsToAgree(current.value, session.legal))
const outstandingKeys = computed(() => new Set(outstanding.value.map((d) => d.doc_key)))
const entryFor = (key: LegalDocKey) => session.legal?.documents.find((d) => d.doc_key === key)

/** "We've updated…" when every outstanding document was agreed to before, in an earlier version. */
const isUpdate = computed(
  () => outstanding.value.length > 0 && outstanding.value.every((d) => isUpdatedSinceAgreed(entryFor(d.doc_key))),
)

const allTicked = computed(
  () => outstanding.value.length > 0 && outstanding.value.every((d) => checked.value[d.id] === true),
)

/**
 * The text and the status disagree about which versions are current (one
 * of them is older than the other), or say there is nothing to agree to
 * while the guard says there is. Re-read both, once per disagreement;
 * if they still disagree, say so rather than offer a Continue that the
 * guard would bounce straight back here.
 */
const disagreement = computed(() => {
  if (!hasDocs.value || session.legalAccepted || !session.legal) return ''
  const shown = current.value.map((d) => d.id)
  const known = session.legal.documents.map((d) => d.document_id)
  const differ = known.some((id) => !shown.includes(id)) || !outstanding.value.length
  return differ ? `${shown.join(',')}|${known.join(',')}` : ''
})
const resyncedFor = ref('')
const resyncing = ref(false)
async function resync() {
  resyncing.value = true
  try {
    await Promise.all([docs.refetch(), session.loadLegalStatus()])
  } finally {
    resyncing.value = false
  }
}
watch(
  disagreement,
  (key) => {
    if (key && key !== resyncedFor.value && !resyncing.value) {
      resyncedFor.value = key
      void resync()
    }
  },
  { immediate: true },
)

const phase = computed<'loading' | 'offline' | 'failed' | 'done' | 'agree'>(() => {
  if (session.isOffline) return 'offline'
  // No text yet, and the query is waiting for a connection.
  if (!hasDocs.value && docs.fetchStatus.value === 'paused') return 'offline'
  if (!hasDocs.value && docs.isPending.value) return 'loading'
  if (!hasDocs.value && docs.isError.value) return 'failed'
  if (!session.legal && session.legalError) return 'failed'
  if (session.legalAccepted) return 'done'
  if (disagreement.value) return resyncing.value || disagreement.value !== resyncedFor.value ? 'loading' : 'failed'
  return 'agree'
})

/** A version on screen was replaced (a refetch after a refusal): say so, drop stale ticks. */
watch(
  () => outstanding.value.map((d) => `${d.doc_key}:${d.id}`),
  (now, before) => {
    const ids = new Set(outstanding.value.map((d) => d.id))
    checked.value = Object.fromEntries(Object.entries(checked.value).filter(([id]) => ids.has(Number(id))))
    if (!before?.length) return
    const was = new Map(before.map((k) => k.split(':') as [string, string]))
    if (now.some((k) => {
      const [key, id] = k.split(':')
      return was.has(key) && was.get(key) !== id
    })) {
      problem.value = legalErrorMessage(new Error('legal_document_not_current'))
    }
  },
)

function leave() {
  void router.replace(destination.value)
}

// Agreed here, in another tab, or the status simply arrived: carry on.
watch(
  () => session.legalAccepted,
  (accepted) => {
    if (accepted) leave()
  },
)

/**
 * Signed out from under this screen (another tab, a revoked session, an
 * account deactivated while offline): go to the sign-in, keeping the way
 * back. AppShell does this for every other page; it is not mounted here.
 * Decline signs out on purpose and lands on a plain sign-in instead.
 */
let declining = false
watch(
  () => session.isSignedIn,
  (signedIn) => {
    if (!signedIn && !declining && session.ready) {
      void router.replace({ name: 'login', query: { redirect: route.query.redirect ? destination.value : undefined } })
    }
  },
)

const LABEL: Record<LegalDocKey, string> = {
  terms:
    'I have read and agree to the Terms of Use, including its confidentiality, monitoring, indemnification (hold harmless) and limitation-of-liability terms.',
  privacy:
    'I have read the Privacy Policy and agree to the collection, use and sharing of my information it describes, including the recording of my sign-ins and my use of the portal.',
}

async function agree() {
  if (!allTicked.value || busy.value) return
  busy.value = 'agree'
  problem.value = ''
  try {
    const status = await session.acceptLegal(outstanding.value.map((d) => d.id))
    if (status.all_accepted) {
      leave()
      return
    }
    // Agreed to what was shown, and something else is still outstanding
    // (a version published in between): show it.
    await docs.refetch()
    problem.value = legalErrorMessage(new Error('legal_document_not_current'))
  } catch (e) {
    problem.value = legalErrorMessage(e)
    if (/legal_document_not_current/.test((e as Error)?.message ?? '')) {
      checked.value = {}
      await Promise.all([docs.refetch(), session.loadLegalStatus()])
    }
  } finally {
    busy.value = null
  }
}

async function retry() {
  busy.value = 'retry'
  problem.value = ''
  try {
    await Promise.all([docs.refetch(), session.loadLegalStatus()])
    // Still disagreeing after a fresh read of both: stay on "didn't load".
    resyncedFor.value = disagreement.value
  } finally {
    busy.value = null
  }
}

async function decline() {
  declining = true
  busy.value = 'decline'
  try {
    await session.signOut()
  } finally {
    busy.value = null
    void router.replace({ name: 'login' })
  }
}
</script>

<template>
  <div class="bg-canvas text-ink flex min-h-svh justify-center px-5 py-10">
    <div class="flex w-full max-w-2xl flex-col">
      <span class="font-label text-accent text-xs font-semibold tracking-[0.24em] uppercase">
        Christensen Arms · Rep Portal
      </span>

      <div v-if="phase === 'loading'" class="mt-6">
        <h1 class="u-display text-3xl leading-tight" role="status">One moment</h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">Loading the Terms of Use and Privacy Policy.</p>
        <div class="mt-6">
          <AppButton variant="ghost" :loading="busy === 'decline'" :disabled="busy !== null" @click="decline">
            Sign out
          </AppButton>
        </div>
      </div>

      <div v-else-if="phase === 'offline'" class="mt-6">
        <h1 class="u-display text-3xl leading-tight">Connect to continue</h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          Before you can use the portal you need to read and agree to the
          Terms of Use and the Privacy Policy, and that needs a connection.
          It opens by itself as soon as you have signal.
        </p>
        <div class="mt-6 flex flex-col gap-2 sm:flex-row">
          <AppButton variant="secondary" :loading="busy === 'decline'" :disabled="busy !== null" @click="decline">
            Sign out
          </AppButton>
        </div>
      </div>

      <div v-else-if="phase === 'failed'" class="mt-6">
        <h1 class="u-display text-3xl leading-tight">This didn’t load</h1>
        <p role="alert" class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          The Terms of Use and Privacy Policy could not be loaded, or your
          agreement could not be checked, so the portal cannot open yet.
          Check your connection and try again.
        </p>
        <div class="mt-6 flex flex-col gap-2 sm:flex-row">
          <AppButton variant="primary" :loading="busy === 'retry'" :disabled="busy !== null" @click="retry">
            Try again
          </AppButton>
          <AppButton variant="secondary" :loading="busy === 'decline'" :disabled="busy !== null" @click="decline">
            Sign out
          </AppButton>
        </div>
      </div>

      <div v-else-if="phase === 'done'" class="mt-6" role="status">
        <h1 class="u-display text-3xl leading-tight">You’re all set</h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          You have agreed to the current Terms of Use and Privacy Policy.
        </p>
        <div class="mt-6">
          <AppButton variant="primary" @click="leave">Continue</AppButton>
        </div>
      </div>

      <template v-else>
        <h1 class="u-display mt-6 text-3xl leading-tight">
          {{ isUpdate ? 'We’ve updated our terms' : 'Before you start' }}
        </h1>
        <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
          <template v-if="isUpdate">
            The documents below have changed since you last agreed to them.
            Please read the current versions; you need to agree to them to
            keep using the Rep Portal.
          </template>
          <template v-else>
            To use the Rep Portal you need to read and agree to the
            <strong class="text-ink">Terms of Use</strong> and the
            <strong class="text-ink">Privacy Policy</strong> below. They are a
            binding agreement. They cover how you may use the portal and the
            confidential information in it, and what the portal records about
            your use of it.
          </template>
        </p>

        <dl class="border-line bg-surface mt-6 border text-sm">
          <div class="px-4 py-3">
            <dt class="u-label text-muted">Agreeing as</dt>
            <dd class="text-ink mt-1 font-semibold">{{ session.displayName }}</dd>
            <dd v-if="session.user?.email" class="text-muted">{{ session.user.email }}</dd>
            <dd v-if="session.isViewingAs" class="text-ink-2 mt-1">
              You are viewing the portal as someone else. This records your
              own agreement, not theirs.
            </dd>
          </div>
        </dl>

        <section
          v-for="doc in current"
          :key="doc.id"
          class="border-line bg-surface mt-6 border"
          :aria-labelledby="`legal-${doc.doc_key}-title`"
        >
          <header class="border-line flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b px-4 py-3">
            <h2 :id="`legal-${doc.doc_key}-title`" class="text-ink text-lg font-semibold">
              {{ doc.title }}
            </h2>
            <p class="text-muted text-xs">
              Version {{ doc.version }} · Effective {{ shortDate(doc.effective_at) }}
            </p>
          </header>

          <p
            v-if="!outstandingKeys.has(doc.doc_key)"
            class="text-ink-2 px-4 py-3 text-sm"
          >
            You agreed to this version on {{ shortDate(entryFor(doc.doc_key)?.accepted_at) }}.
            <RouterLink
              :to="{ name: LEGAL_DOC_ROUTE[doc.doc_key] }"
              target="_blank"
              class="underline underline-offset-2"
            >Read it again</RouterLink>.
          </p>

          <template v-else>
            <p
              v-if="isUpdatedSinceAgreed(entryFor(doc.doc_key))"
              class="border-line bg-canvas border-l-accent mx-4 mt-3 border border-l-[3px] px-3 py-2 text-sm"
            >
              Updated since you agreed to version
              {{ entryFor(doc.doc_key)?.last_accepted_version }} on
              {{ shortDate(entryFor(doc.doc_key)?.last_accepted_at) }}.
            </p>

            <div v-if="doc.summary" class="px-4 pt-3">
              <h3 class="u-label text-ink">In short</h3>
              <div class="prose-help mt-1" v-html="renderMarkdown(doc.summary)" />
              <p class="text-muted mt-2 text-xs">
                This summary is for convenience only. The full text below is
                what you are agreeing to.
              </p>
            </div>

            <div
              class="prose-help border-line mx-4 mt-3 max-h-[55svh] overflow-y-auto border p-4"
              tabindex="0"
              role="region"
              :aria-label="`${doc.title}, full text`"
              v-html="renderMarkdown(doc.body_md)"
            />
            <p class="px-4 pt-2 text-xs">
              <RouterLink
                :to="{ name: LEGAL_DOC_ROUTE[doc.doc_key] }"
                target="_blank"
                class="text-ink-2 underline underline-offset-2"
              >Open the {{ LEGAL_DOC_LABEL[doc.doc_key] }} on its own page</RouterLink>
              (to read full screen or print).
            </p>

            <label class="border-line bg-canvas m-4 flex min-h-12 cursor-pointer items-start gap-3 border px-3 py-3">
              <input
                v-model="checked[doc.id]"
                type="checkbox"
                class="mt-0.5 size-6 shrink-0"
                :disabled="busy !== null"
              />
              <span class="text-ink text-[15px] font-semibold leading-snug">{{ LABEL[doc.doc_key] }}</span>
            </label>
          </template>
        </section>

        <p v-if="docs.isRefetchError.value" role="status" class="text-muted mt-5 text-sm">
          Couldn’t check for a newer version just now. You can still agree to
          the text shown: if it has been replaced, you will be shown the new one.
        </p>
        <p v-if="problem" role="alert" class="text-danger mt-5 text-sm">{{ problem }}</p>

        <div class="mt-6 flex flex-col gap-2">
          <AppButton
            variant="primary"
            size="lg"
            block
            :loading="busy === 'agree'"
            :disabled="!allTicked || busy !== null"
            @click="agree"
          >
            Agree and continue
          </AppButton>
          <AppButton
            variant="secondary"
            block
            :loading="busy === 'decline'"
            :disabled="busy !== null"
            @click="decline"
          >
            Decline and sign out
          </AppButton>
        </div>

        <p class="text-muted mt-5 text-xs leading-relaxed">
          Selecting <strong>Agree and continue</strong> is your electronic
          signature and has the same effect as signing on paper. The portal
          records which versions you agreed to, when, and the network address
          and browser you agreed from. You can read both documents again at
          any time from your account menu. If you do not agree, you cannot use
          the portal; ask your Christensen Arms contact if you have questions.
        </p>
      </template>

      <div class="border-line mt-10 flex items-center gap-2.5 border-t pt-4">
        <span class="bg-accent block h-4 w-[3px]" aria-hidden="true" />
        <span class="font-label text-muted text-xs font-semibold tracking-[0.16em] uppercase">
          Rep Portal · Field Sales
        </span>
      </div>
    </div>
  </div>
</template>
