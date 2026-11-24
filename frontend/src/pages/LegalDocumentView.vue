<script setup lang="ts">
import { computed, watch } from 'vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useSessionStore } from '@/stores/session'
import { useLegalDocuments } from '@/composables/useLegal'
import { renderMarkdown } from '@/lib/markdown'
import { shortDate } from '@/lib/format'
import { LEGAL_DOC_KEYS, LEGAL_DOC_LABEL, LEGAL_DOC_ROUTE, type LegalDocKey } from '@/lib/legal'

/**
 * /terms and /privacy: the version of the document in force, readable by
 * anyone, signed in or not (legal_current_documents() is granted to anon).
 * Linked from the sign-in screen, the agreement screen and the account menu.
 * Full-bleed like the other public pages, and printable.
 */
const props = defineProps<{ docKey: LegalDocKey }>()

const session = useSessionStore()
const docs = useLegalDocuments()

const doc = computed(() => (docs.data.value ?? []).find((d) => d.doc_key === props.docKey) ?? null)
const other = computed(() => LEGAL_DOC_KEYS.find((k) => k !== props.docKey) as LegalDocKey)
const mine = computed(() => session.legal?.documents.find((d) => d.doc_key === props.docKey) ?? null)
/** Only ever claim an agreement to the version that is on screen. */
const agreedToShown = computed(
  () => !!doc.value && !!mine.value?.accepted_at && mine.value.document_id === doc.value.id,
)
/** Offline with nothing loaded yet: the query waits for a connection. */
const waitingForSignal = computed(() => docs.fetchStatus.value === 'paused' && docs.data.value === undefined)

// This page found a newer version than the signed-in status knows about:
// re-read the status, so the guard (and "Back to the portal") asks for it.
watch(
  () => [doc.value?.id, mine.value?.document_id] as const,
  ([shown, known]) => {
    if (session.isSignedIn && !session.isOffline && shown != null && known != null && shown !== known) {
      void session.loadLegalStatus()
    }
  },
)

function print() {
  window.print()
}
</script>

<template>
  <div class="bg-canvas text-ink flex min-h-svh justify-center px-5 py-10">
    <div class="flex w-full max-w-2xl flex-col">
      <div class="flex flex-wrap items-center justify-between gap-3 print:hidden">
        <span class="font-label text-accent text-xs font-semibold tracking-[0.24em] uppercase">
          Christensen Arms · Rep Portal
        </span>
        <nav class="flex gap-4 text-sm" aria-label="Legal documents">
          <RouterLink
            v-for="key in LEGAL_DOC_KEYS"
            :key="key"
            :to="{ name: LEGAL_DOC_ROUTE[key] }"
            class="tap-target font-label inline-flex items-center text-[13px] font-semibold tracking-[0.12em] uppercase"
            :class="key === docKey ? 'text-ink underline underline-offset-4' : 'text-muted'"
            :aria-current="key === docKey ? 'page' : undefined"
          >
            {{ LEGAL_DOC_LABEL[key] }}
          </RouterLink>
        </nav>
      </div>

      <AsyncState
        :loading="docs.isPending.value && !waitingForSignal"
        :error="docs.error.value"
        :has-data="!!doc"
        :empty="waitingForSignal || !doc"
        :empty-title="waitingForSignal ? 'You’re offline' : 'Not published yet'"
        :empty-body="
          waitingForSignal
            ? `The ${LEGAL_DOC_LABEL[docKey]} needs a connection to load. It appears as soon as you have signal.`
            : `There is no ${LEGAL_DOC_LABEL[docKey]} in force at the moment.`
        "
        @retry="docs.refetch()"
      >
        <article v-if="doc" class="mt-6">
          <h1 class="u-display text-3xl leading-tight">{{ doc.title }}</h1>
          <p class="text-muted mt-2 text-sm">
            Version {{ doc.version }} · Effective {{ shortDate(doc.effective_at) }}
          </p>
          <p v-if="agreedToShown" class="text-ink-2 mt-1 text-sm">
            You agreed to this version on {{ shortDate(mine?.accepted_at) }}.
          </p>
          <p v-else-if="mine?.last_accepted_version || (mine?.accepted_at && mine.document_id !== doc.id)" class="text-ink-2 mt-1 text-sm">
            This version is new since you last agreed. You will be asked to agree to it.
          </p>

          <div v-if="doc.summary" class="border-line bg-surface mt-6 border px-4 py-3">
            <h2 class="u-label text-ink">In short</h2>
            <div class="prose-help mt-1" v-html="renderMarkdown(doc.summary)" />
            <p class="text-muted mt-2 text-xs">
              This summary is for convenience only; the full text below governs.
            </p>
          </div>

          <div class="prose-help mt-6" v-html="renderMarkdown(doc.body_md)" />

          <p class="text-muted mt-8 text-xs">
            Document fingerprint (SHA-256): <span class="font-mono break-all">{{ doc.content_sha256 }}</span>
          </p>
        </article>
      </AsyncState>

      <div class="mt-8 flex flex-col gap-2 sm:flex-row print:hidden">
        <RouterLink v-if="session.isSignedIn" :to="{ name: 'overview' }">
          <AppButton variant="secondary" block>Back to the portal</AppButton>
        </RouterLink>
        <RouterLink v-else :to="{ name: 'login' }">
          <AppButton variant="secondary" block>Sign in</AppButton>
        </RouterLink>
        <RouterLink :to="{ name: LEGAL_DOC_ROUTE[other] }">
          <AppButton variant="ghost" block>Read the {{ LEGAL_DOC_LABEL[other] }}</AppButton>
        </RouterLink>
        <AppButton v-if="doc" variant="ghost" @click="print">Print</AppButton>
      </div>

      <div class="border-line mt-10 flex items-center gap-2.5 border-t pt-4">
        <span class="bg-accent block h-4 w-[3px]" aria-hidden="true" />
        <span class="font-label text-muted text-xs font-semibold tracking-[0.16em] uppercase">
          Rep Portal · Field Sales
        </span>
      </div>
    </div>
  </div>
</template>
