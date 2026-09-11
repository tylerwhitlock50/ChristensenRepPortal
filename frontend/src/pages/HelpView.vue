<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute } from 'vue-router'
import { useSessionStore } from '@/stores/session'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import SupportThread from '@/components/SupportThread.vue'
import { renderMarkdown } from '@/lib/markdown'
import { daysAgo } from '@/lib/format'
import {
  CATEGORY_LABELS,
  STATUS_LABELS,
  useAskQuestion,
  useHelpArticles,
  useMySupportRequests,
  type HelpArticle,
  type SupportCategory,
} from '@/composables/useSupport'

/**
 * Help & support — the page a rep lands on from the "?" in the header.
 *
 * Three things, in the order a stuck rep needs them: the how-tos (searchable,
 * because "how do I find an order" should be one keystroke away), a question
 * box that writes to the database with the page and device attached, and
 * their own questions with the answers under them.
 */
const session = useSessionStore()
const route = useRoute()

/* ---- articles ----------------------------------------------------------- */
const articles = useHelpArticles()
const search = ref('')
const openSlug = ref<string | null>(
  typeof route.query.article === 'string' ? route.query.article : null,
)

const filtered = computed<HelpArticle[]>(() => {
  const q = search.value.trim().toLowerCase()
  const rows = articles.data.value ?? []
  if (!q) return rows
  return rows.filter((a) =>
    `${a.title} ${a.summary ?? ''} ${a.category} ${a.body}`.toLowerCase().includes(q),
  )
})

/** Category order follows the first article seen in sort order. */
const groups = computed(() => {
  const byCategory = new Map<string, HelpArticle[]>()
  for (const a of filtered.value) {
    if (!byCategory.has(a.category)) byCategory.set(a.category, [])
    byCategory.get(a.category)!.push(a)
  }
  return [...byCategory.entries()].map(([category, items]) => ({ category, items }))
})

function toggle(slug: string) {
  openSlug.value = openSlug.value === slug ? null : slug
}

/* ---- ask ---------------------------------------------------------------- */
const ask = useAskQuestion()
const category = ref<SupportCategory>('question')
const subject = ref('')
const body = ref('')
const askError = ref('')
const askedNotice = ref('')

/** The page the rep came FROM, if the "?" carried it; else this page. */
const fromPath = computed(() =>
  typeof route.query.from === 'string' && route.query.from.startsWith('/')
    ? route.query.from
    : route.fullPath,
)

const canAsk = computed(
  () => session.canWrite && subject.value.trim().length > 0 && body.value.trim().length > 0,
)

async function submit() {
  askError.value = ''
  askedNotice.value = ''
  try {
    await ask.mutateAsync({
      subject: subject.value,
      category: category.value,
      body: body.value,
      pagePath: fromPath.value,
    })
    subject.value = ''
    body.value = ''
    category.value = 'question'
    askedNotice.value = "Sent. You'll see the answer under Your questions below."
  } catch (e) {
    askError.value = (e as Error).message || 'Could not send that. Try again.'
  }
}

/* ---- my questions ------------------------------------------------------- */
const mine = useMySupportRequests()
const openRequest = ref<number | null>(null)

function statusTone(status: string): 'late' | 'high' | 'good' | 'neutral' {
  if (status === 'answered') return 'high'
  if (status === 'closed') return 'good'
  return 'neutral'
}
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Help
      </p>
      <h1 class="u-display mt-1 text-[34px]">How to, and who to ask</h1>
      <p class="text-muted mt-2 text-[15px]">
        Short guides first. If they don't cover it, ask below — the answer comes
        back here.
      </p>
    </header>

    <!-- Guides -->
    <AppCard :padded="false">
      <template #header>
        <h2 class="u-label text-ink">Guides</h2>
        <label class="sr-only" for="help-search">Search the guides</label>
        <input
          id="help-search"
          v-model="search"
          type="search"
          class="field max-w-56"
          placeholder="Search guides…"
          autocomplete="off"
        />
      </template>

      <AsyncState
        :loading="articles.isPending.value"
        :error="articles.error.value"
        :empty="filtered.length === 0"
        :empty-title="search ? 'No guide matches that' : 'No guides yet'"
        :empty-body="search ? 'Try a different word, or ask below.' : 'Ask a question below and we will write one.'"
        :rows="4"
        @retry="articles.refetch()"
      >
        <div class="divide-line divide-y">
          <section v-for="group in groups" :key="group.category">
            <h3
              class="font-label text-muted bg-canvas border-line border-b px-4 py-2 text-xs font-semibold tracking-[0.18em] uppercase"
            >
              {{ group.category }}
            </h3>
            <ul class="divide-line divide-y">
              <li v-for="a in group.items" :key="a.slug">
                <button
                  type="button"
                  class="tap-target flex w-full items-start justify-between gap-3 px-4 py-3 text-left hover:bg-canvas"
                  :aria-expanded="openSlug === a.slug"
                  :aria-controls="`article-${a.slug}`"
                  @click="toggle(a.slug)"
                >
                  <span class="min-w-0">
                    <span class="text-ink block text-[17px] font-semibold">{{ a.title }}</span>
                    <span v-if="a.summary" class="text-muted mt-0.5 block text-[15px]">
                      {{ a.summary }}
                    </span>
                  </span>
                  <svg
                    class="text-muted mt-1 size-5 shrink-0 transition-transform"
                    :class="openSlug === a.slug ? 'rotate-180' : ''"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M6 9l6 6 6-6" />
                  </svg>
                </button>
                <!-- Rendered from our own escaped Markdown (lib/markdown.ts);
                     the only HTML that can appear is the tag set it emits. -->
                <div
                  v-if="openSlug === a.slug"
                  :id="`article-${a.slug}`"
                  class="prose-help border-line border-t px-4 py-4"
                  v-html="renderMarkdown(a.body)"
                />
              </li>
            </ul>
          </section>
        </div>
      </AsyncState>
    </AppCard>

    <!-- Ask -->
    <AppCard title="Ask a question">
      <p class="text-muted text-[15px]">
        Questions, problems and ideas all land in the same inbox. The screen
        you were on and your device details are attached for you.
      </p>

      <form class="mt-4 space-y-4" @submit.prevent="submit">
        <div class="flex flex-wrap gap-2" role="radiogroup" aria-label="What kind of message">
          <button
            v-for="(label, key) in CATEGORY_LABELS"
            :key="key"
            type="button"
            role="radio"
            :aria-checked="category === key"
            class="tap-target font-label rounded-[2px] px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
            :class="category === key ? 'bg-ink text-canvas' : 'border-line-2 text-ink-2 border'"
            @click="category = key"
          >
            {{ label }}
          </button>
        </div>

        <label class="block">
          <span class="u-label mb-1.5 block">In a few words</span>
          <input
            v-model="subject"
            type="text"
            class="field"
            maxlength="200"
            placeholder="Can't find last month's shipments for…"
            required
          />
        </label>

        <label class="block">
          <span class="u-label mb-1.5 block">What happened, or what you're trying to do</span>
          <textarea
            v-model="body"
            class="field min-h-32"
            maxlength="8000"
            placeholder="The account or order number you were looking at helps."
            required
          />
        </label>

        <p v-if="!session.canWrite" class="text-muted text-sm">
          You're viewing as someone else — questions can't be sent from here.
        </p>
        <p v-if="askError" role="alert" class="text-danger text-sm font-medium">
          {{ askError }}
        </p>
        <p v-if="askedNotice" role="status" class="text-ink text-sm font-medium">
          {{ askedNotice }}
        </p>

        <AppButton
          type="submit"
          variant="primary"
          :loading="ask.isPending.value"
          :disabled="!canAsk"
        >
          Send
        </AppButton>
      </form>
    </AppCard>

    <!-- Mine -->
    <AppCard title="Your questions" :padded="false">
      <AsyncState
        :loading="mine.isPending.value"
        :error="mine.error.value"
        :empty="(mine.data.value ?? []).length === 0"
        empty-title="Nothing asked yet"
        empty-body="Your questions and the answers will stay here."
        :rows="2"
        @retry="mine.refetch()"
      >
        <ul class="divide-line divide-y">
          <li v-for="r in mine.data.value" :key="r.id">
            <button
              type="button"
              class="tap-target flex w-full items-start justify-between gap-3 px-4 py-3 text-left hover:bg-canvas"
              :aria-expanded="openRequest === r.id"
              @click="openRequest = openRequest === r.id ? null : r.id"
            >
              <span class="min-w-0">
                <span class="text-ink block truncate text-[17px] font-semibold">
                  {{ r.subject }}
                </span>
                <span class="text-muted mt-0.5 block text-[13px]">
                  {{ CATEGORY_LABELS[r.category] }} · {{ daysAgo(r.updated_at) }}
                </span>
              </span>
              <AppBadge :tone="statusTone(r.status)" class="shrink-0">
                {{ STATUS_LABELS[r.status] }}
              </AppBadge>
            </button>
            <SupportThread
              v-if="openRequest === r.id"
              :request="r"
              class="border-line border-t px-4 py-4"
            />
          </li>
        </ul>
      </AsyncState>
    </AppCard>
  </div>
</template>
