<script setup lang="ts">
/**
 * Support — the admin inbox and the help-article editor.
 *
 * Questions come in from /help with the page and device attached; the
 * answer is typed here and the rep reads it on the same page they asked
 * from. A mailto link is offered as a side channel (a long reply is easier
 * in a mail client), but the in-portal reply is what marks it answered.
 */
import { computed, ref, watch } from 'vue'
import { useProfiles } from '@/composables/useAdminUsers'
import {
  CATEGORY_LABELS,
  STATUS_LABELS,
  useAllHelpArticles,
  useDeleteHelpArticle,
  useSaveHelpArticle,
  useSupportInbox,
  type ArticleInput,
  type HelpArticle,
  type SupportRequest,
  type SupportStatus,
} from '@/composables/useSupport'
import SupportThread from '@/components/SupportThread.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { renderMarkdown } from '@/lib/markdown'
import { daysAgo } from '@/lib/format'

/* ---- inbox -------------------------------------------------------------- */
const inbox = useSupportInbox()
const profiles = useProfiles()

const profileById = computed(() => {
  const map: Record<string, { name: string; email: string | null }> = {}
  for (const p of profiles.data.value ?? []) {
    map[p.user_id] = {
      name: p.full_name || p.email || p.user_id,
      email: (p as { email?: string | null }).email ?? null,
    }
  }
  return map
})

type Filter = SupportStatus | 'all'
const FILTERS: { key: Filter; label: string }[] = [
  { key: 'open', label: 'Waiting' },
  { key: 'answered', label: 'Answered' },
  { key: 'closed', label: 'Solved' },
  { key: 'all', label: 'All' },
]
const filter = ref<Filter>('open')

const requests = computed(() => inbox.data.value ?? [])
const openCount = computed(() => requests.value.filter((r) => r.status === 'open').length)
const answeredCount = computed(() => requests.value.filter((r) => r.status === 'answered').length)
const visible = computed(() =>
  filter.value === 'all' ? requests.value : requests.value.filter((r) => r.status === filter.value),
)
const openRequest = ref<number | null>(null)

function requester(r: SupportRequest) {
  return profileById.value[r.user_id] ?? { name: 'Unknown user', email: null }
}

function mailto(r: SupportRequest): string | null {
  const email = requester(r).email
  if (!email) return null
  const subject = encodeURIComponent(`Re: ${r.subject} (Rep Portal)`)
  return `mailto:${email}?subject=${subject}`
}

function statusTone(status: string): 'late' | 'high' | 'good' | 'neutral' {
  if (status === 'open') return 'late'
  if (status === 'answered') return 'high'
  if (status === 'closed') return 'good'
  return 'neutral'
}

function contextLines(r: SupportRequest): string[] {
  const c = r.context ?? {}
  const out: string[] = []
  if (r.page_path) out.push(`Page: ${r.page_path}`)
  if (typeof c.viewport === 'string') out.push(`Viewport: ${c.viewport}`)
  if (typeof c.userAgent === 'string') out.push(`Browser: ${c.userAgent}`)
  if (c.online === false) out.push('Was offline when sent')
  return out
}

/* ---- articles ----------------------------------------------------------- */
const articles = useAllHelpArticles()
const save = useSaveHelpArticle()
const remove = useDeleteHelpArticle()

const blank = (): ArticleInput => ({
  slug: '',
  title: '',
  summary: '',
  body: '',
  category: 'How to',
  sort_order: 100,
  published: false,
})
const editing = ref<ArticleInput | null>(null)
const articleError = ref('')
const articleNotice = ref('')
const confirmingDelete = ref<number | null>(null)
const showPreview = ref(false)

const categories = computed(() => {
  const set = new Set<string>(['Start here', 'How to', 'Best practice'])
  for (const a of articles.data.value ?? []) set.add(a.category)
  return [...set]
})

function startNew() {
  editing.value = blank()
  articleError.value = ''
  articleNotice.value = ''
  showPreview.value = false
}
function startEdit(a: HelpArticle) {
  const { updated_at: _u, ...rest } = a
  editing.value = { ...rest, summary: rest.summary ?? '' }
  articleError.value = ''
  articleNotice.value = ''
  showPreview.value = false
}

function slugify(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}
/** Fill the slug from the title until the admin edits the slug by hand. */
watch(
  () => editing.value?.title,
  (title) => {
    if (!editing.value || editing.value.id) return
    editing.value.slug = slugify(title ?? '')
  },
)

async function saveArticle() {
  if (!editing.value) return
  articleError.value = ''
  articleNotice.value = ''
  const input = { ...editing.value, slug: slugify(editing.value.slug) }
  if (!input.title.trim() || !input.slug) {
    articleError.value = 'A title (and the slug it makes) is required.'
    return
  }
  try {
    const saved = await save.mutateAsync({
      ...input,
      summary: input.summary?.trim() || null,
    })
    editing.value = { ...editing.value, id: saved.id, slug: saved.slug }
    articleNotice.value = saved.published ? 'Saved and live for reps.' : 'Saved as a draft.'
  } catch (e) {
    articleError.value = (e as Error).message || 'Could not save that.'
  }
}

async function togglePublished(a: HelpArticle) {
  articleError.value = ''
  try {
    const { updated_at: _u, ...rest } = a
    await save.mutateAsync({ ...rest, published: !a.published })
  } catch (e) {
    articleError.value = (e as Error).message || 'Could not save that.'
  }
}

async function deleteArticle(id: number) {
  articleError.value = ''
  try {
    await remove.mutateAsync(id)
    if (editing.value?.id === id) editing.value = null
  } catch (e) {
    articleError.value = (e as Error).message || 'Could not delete that.'
  } finally {
    confirmingDelete.value = null
  }
}
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Support
      </p>
      <h1 class="u-display mt-1 text-4xl">Questions from the field</h1>
      <p class="text-muted mt-2 text-[15px]">
        Answer here and the rep sees it on their Help page. Write the guides
        below so the next rep doesn't have to ask.
      </p>
    </header>

    <div class="bg-line border-line grid grid-cols-3 gap-px border">
      <StatTile
        label="Waiting"
        :value="inbox.isPending.value ? '—' : openCount"
        sub="need a reply"
        :tone="openCount > 0 ? 'alert' : 'default'"
      />
      <StatTile
        label="Answered"
        :value="inbox.isPending.value ? '—' : answeredCount"
        sub="rep hasn't closed"
      />
      <StatTile
        label="Guides"
        :value="articles.isPending.value ? '—' : (articles.data.value ?? []).filter((a) => a.published).length"
        sub="published"
      />
    </div>

    <!-- Inbox -->
    <AppCard :padded="false">
      <template #header>
        <h2 class="u-label text-ink">Inbox</h2>
        <div class="flex gap-1">
          <button
            v-for="f in FILTERS"
            :key="f.key"
            type="button"
            class="tap-target font-label rounded-[2px] px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
            :class="filter === f.key ? 'bg-ink text-canvas' : 'text-muted'"
            :aria-pressed="filter === f.key"
            @click="filter = f.key"
          >
            {{ f.label }}
          </button>
        </div>
      </template>

      <AsyncState
        :loading="inbox.isPending.value"
        :error="inbox.error.value"
        :empty="visible.length === 0"
        :empty-title="filter === 'open' ? 'Inbox zero' : 'Nothing here'"
        :empty-body="filter === 'open' ? 'No questions are waiting on you.' : ''"
        :rows="3"
        @retry="inbox.refetch()"
      >
        <ul class="divide-line divide-y">
          <li v-for="r in visible" :key="r.id">
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
                  {{ requester(r).name }} · {{ CATEGORY_LABELS[r.category] }} ·
                  {{ daysAgo(r.updated_at) }}
                  <template v-if="r.page_path"> · {{ r.page_path }}</template>
                </span>
              </span>
              <AppBadge :tone="statusTone(r.status)" class="shrink-0">
                {{ STATUS_LABELS[r.status] }}
              </AppBadge>
            </button>

            <div v-if="openRequest === r.id" class="border-line bg-canvas border-t px-4 py-4">
              <div class="mb-4 flex flex-wrap items-start justify-between gap-3">
                <dl class="text-muted space-y-0.5 text-[13px]">
                  <div v-for="line in contextLines(r)" :key="line" class="break-all">{{ line }}</div>
                </dl>
                <a
                  v-if="mailto(r)"
                  :href="mailto(r)!"
                  class="tap-target font-label border-line text-ink hover:border-ink inline-flex items-center rounded-[2px] border px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
                >
                  Email {{ requester(r).name.split(' ')[0] }}
                </a>
              </div>
              <SupportThread :request="r" :requester-name="requester(r).name" />
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

    <!-- Guides -->
    <AppCard :padded="false">
      <template #header>
        <h2 class="u-label text-ink">Guides</h2>
        <AppButton variant="secondary" @click="startNew">New guide</AppButton>
      </template>

      <p v-if="articleError" role="alert" class="text-danger px-4 pt-3 text-sm font-medium">
        {{ articleError }}
      </p>

      <AsyncState
        :loading="articles.isPending.value"
        :error="articles.error.value"
        :empty="(articles.data.value ?? []).length === 0"
        empty-title="No guides yet"
        empty-body="Write the first one — what reps ask most."
        :rows="3"
        @retry="articles.refetch()"
      >
        <ul class="divide-line divide-y">
          <li
            v-for="a in articles.data.value"
            :key="a.id"
            class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
          >
            <div class="min-w-0">
              <p class="text-ink truncate font-semibold">
                {{ a.title }}
                <AppBadge v-if="!a.published" tone="neutral" class="ml-2">Draft</AppBadge>
              </p>
              <p class="text-muted mt-0.5 text-[13px]">
                {{ a.category }} · #{{ a.sort_order }} · updated {{ daysAgo(a.updated_at) }}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <AppButton variant="ghost" @click="startEdit(a)">Edit</AppButton>
              <AppButton variant="ghost" :loading="save.isPending.value" @click="togglePublished(a)">
                {{ a.published ? 'Unpublish' : 'Publish' }}
              </AppButton>
              <AppButton
                v-if="confirmingDelete !== a.id"
                variant="ghost"
                @click="confirmingDelete = a.id"
              >
                Delete
              </AppButton>
              <AppButton
                v-else
                variant="danger"
                :loading="remove.isPending.value"
                @click="deleteArticle(a.id)"
              >
                Really delete
              </AppButton>
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

    <!-- Editor -->
    <AppCard v-if="editing" :title="editing.id ? 'Edit guide' : 'New guide'">
      <form class="space-y-4" @submit.prevent="saveArticle">
        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block sm:col-span-2">
            <span class="u-label mb-1.5 block">Title</span>
            <input v-model="editing.title" type="text" class="field" maxlength="160" required />
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Summary (one line under the title)</span>
            <input v-model="editing.summary" type="text" class="field" maxlength="200" />
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Category</span>
            <input v-model="editing.category" type="text" class="field" list="help-categories" maxlength="60" />
            <datalist id="help-categories">
              <option v-for="c in categories" :key="c" :value="c" />
            </datalist>
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Slug (in the link)</span>
            <input v-model="editing.slug" type="text" class="field" pattern="[a-z0-9]+(-[a-z0-9]+)*" />
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Order (lower shows first)</span>
            <input v-model.number="editing.sort_order" type="number" class="field" min="0" />
          </label>
        </div>

        <label class="block">
          <span class="u-label mb-1.5 block">Body</span>
          <textarea v-model="editing.body" class="field min-h-72 font-mono text-[14px]" />
          <span class="text-muted mt-1 block text-[13px]">
            Plain text with a little Markdown: <code>## Heading</code>, <code>- bullet</code>,
            <code>1. step</code>, <code>**bold**</code>, <code>[link](https://…)</code>.
          </span>
        </label>

        <label class="flex items-center gap-2">
          <input v-model="editing.published" type="checkbox" class="size-5" />
          <span class="text-ink text-[15px]">Published — reps can see it</span>
        </label>

        <p v-if="articleNotice" role="status" class="text-ink text-sm font-medium">
          {{ articleNotice }}
        </p>

        <div class="flex flex-wrap gap-2">
          <AppButton type="submit" variant="primary" :loading="save.isPending.value">
            Save
          </AppButton>
          <AppButton variant="ghost" @click="showPreview = !showPreview">
            {{ showPreview ? 'Hide preview' : 'Preview' }}
          </AppButton>
          <AppButton variant="ghost" @click="editing = null">Close</AppButton>
        </div>
      </form>

      <div
        v-if="showPreview"
        class="prose-help border-line mt-4 border p-4"
        v-html="renderMarkdown(editing.body)"
      />
    </AppCard>
  </div>
</template>
