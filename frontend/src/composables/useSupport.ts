import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'

/**
 * Help articles and the support inbox (migration 20260908120000).
 *
 * Reps read published articles, ask questions, and follow their own threads.
 * Admins manage articles and answer everything. RLS is the boundary on every
 * call below; the `user_id` filter on the rep's list exists only so an admin
 * reading /help sees their own questions rather than the whole inbox.
 */

/** 20260908120000 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useAppSettings.ts. */
const db = supabase as unknown as SupabaseClient

export interface HelpArticle {
  id: number
  slug: string
  title: string
  summary: string | null
  body: string
  category: string
  sort_order: number
  published: boolean
  updated_at: string
}

export type SupportCategory = 'question' | 'problem' | 'idea'
export type SupportStatus = 'open' | 'answered' | 'closed'

export interface SupportRequest {
  id: number
  user_id: string
  subject: string
  category: SupportCategory
  page_path: string | null
  context: Record<string, unknown>
  status: SupportStatus
  created_at: string
  updated_at: string
}

export interface SupportMessage {
  id: number
  request_id: number
  author_id: string
  from_admin: boolean
  body: string
  created_at: string
}

export const CATEGORY_LABELS: Record<SupportCategory, string> = {
  question: 'Question',
  problem: 'Problem',
  idea: 'Idea',
}

export const STATUS_LABELS: Record<SupportStatus, string> = {
  open: 'Waiting for a reply',
  answered: 'Answered',
  closed: 'Solved',
}

export const supportKeys = {
  root: () => ['support'] as const,
  articles: (all: boolean) => ['support', 'articles', all ? 'all' : 'published'] as const,
  mine: (userId: string) => ['support', 'mine', userId] as const,
  inbox: () => ['support', 'inbox'] as const,
  openCount: () => ['support', 'open-count'] as const,
  thread: (requestId: number) => ['support', 'thread', requestId] as const,
} as const

/* ---- articles ----------------------------------------------------------- */

const ARTICLE_COLUMNS =
  'id, slug, title, summary, body, category, sort_order, published, updated_at'

/** Published articles, in reading order. What every rep sees on /help. */
export function useHelpArticles() {
  return useQuery({
    queryKey: supportKeys.articles(false),
    queryFn: async (): Promise<HelpArticle[]> => {
      const { data, error } = await db
        .from('help_articles')
        .select(ARTICLE_COLUMNS)
        .eq('published', true)
        .order('sort_order')
        .order('title')
      if (error) throw error
      return (data ?? []) as HelpArticle[]
    },
    staleTime: 5 * 60_000,
  })
}

/** Admin: every article including drafts. */
export function useAllHelpArticles() {
  const session = useSessionStore()
  return useQuery({
    queryKey: supportKeys.articles(true),
    enabled: computed(() => session.isAdmin),
    queryFn: async (): Promise<HelpArticle[]> => {
      const { data, error } = await db
        .from('help_articles')
        .select(ARTICLE_COLUMNS)
        .order('sort_order')
        .order('title')
      if (error) throw error
      return (data ?? []) as HelpArticle[]
    },
  })
}

export type ArticleInput = Omit<HelpArticle, 'id' | 'updated_at'> & { id?: number }

/** Admin: create (no id) or update (id) one article. */
export function useSaveHelpArticle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: ArticleInput): Promise<HelpArticle> => {
      const { id, ...fields } = input
      const query = id
        ? db.from('help_articles').update(fields).eq('id', id)
        : db.from('help_articles').insert(fields)
      const { data, error } = await query.select(ARTICLE_COLUMNS).single()
      if (error) throw error
      return data as HelpArticle
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['support', 'articles'] })
    },
  })
}

export function useDeleteHelpArticle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: number) => {
      const { error } = await db.from('help_articles').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['support', 'articles'] })
    },
  })
}

/* ---- requests: the rep side --------------------------------------------- */

const REQUEST_COLUMNS =
  'id, user_id, subject, category, page_path, context, status, created_at, updated_at'

export function useMySupportRequests() {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')
  return useQuery({
    queryKey: computed(() => supportKeys.mine(userId.value)),
    enabled: computed(() => !!userId.value),
    queryFn: async (): Promise<SupportRequest[]> => {
      const { data, error } = await db
        .from('support_requests')
        .select(REQUEST_COLUMNS)
        .eq('user_id', userId.value)
        .order('updated_at', { ascending: false })
        .limit(100)
      if (error) throw error
      return (data ?? []) as SupportRequest[]
    },
    staleTime: 30_000,
  })
}

/** The messages under one request. Fetched when the thread is opened. */
export function useSupportThread(requestId: MaybeRef<number | null>) {
  const id = computed(() => unref(requestId))
  return useQuery({
    queryKey: computed(() => supportKeys.thread(id.value ?? 0)),
    enabled: computed(() => !!id.value),
    queryFn: async (): Promise<SupportMessage[]> => {
      const { data, error } = await db
        .from('support_messages')
        .select('id, request_id, author_id, from_admin, body, created_at')
        .eq('request_id', id.value)
        .order('created_at')
        .limit(200)
      if (error) throw error
      return (data ?? []) as SupportMessage[]
    },
  })
}

/**
 * What the client can attach without the rep typing it: the screen they were
 * on and enough about the device to reproduce a layout problem.
 */
export function captureContext(pagePath: string): Record<string, unknown> {
  return {
    page: pagePath,
    userAgent: navigator.userAgent,
    viewport: `${window.innerWidth}x${window.innerHeight}`,
    language: navigator.language,
    online: navigator.onLine,
    askedAt: new Date().toISOString(),
  }
}

export interface AskInput {
  subject: string
  category: SupportCategory
  body: string
  pagePath: string
}

/** Rep: open a request and post its first message. */
export function useAskQuestion() {
  const qc = useQueryClient()
  const session = useSessionStore()
  return useMutation({
    mutationFn: async (input: AskInput): Promise<SupportRequest> => {
      const { data, error } = await db
        .from('support_requests')
        .insert({
          user_id: session.user?.id,
          subject: input.subject.trim(),
          category: input.category,
          page_path: input.pagePath,
          context: captureContext(input.pagePath),
        })
        .select(REQUEST_COLUMNS)
        .single()
      if (error) throw error
      const request = data as SupportRequest

      const { error: msgError } = await db.from('support_messages').insert({
        request_id: request.id,
        author_id: session.user?.id,
        body: input.body.trim(),
      })
      if (msgError) {
        // A request with no text under it is noise in the inbox. Best-effort
        // tidy; the requester's own delete is not granted, so this may be a
        // no-op and that is acceptable.
        await db.from('support_requests').delete().eq('id', request.id)
        throw msgError
      }
      return request
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: supportKeys.root() })
    },
  })
}

/** Either side: add to a thread. The trigger moves the status. */
export function usePostSupportMessage() {
  const qc = useQueryClient()
  const session = useSessionStore()
  return useMutation({
    mutationFn: async (input: { requestId: number; body: string }) => {
      const { error } = await db.from('support_messages').insert({
        request_id: input.requestId,
        author_id: session.user?.id,
        body: input.body.trim(),
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: supportKeys.root() })
    },
  })
}

/** Either side: solved / reopen. */
export function useSetSupportStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { requestId: number; status: SupportStatus }) => {
      const { error } = await db
        .from('support_requests')
        .update({ status: input.status, updated_at: new Date().toISOString() })
        .eq('id', input.requestId)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: supportKeys.root() })
    },
  })
}

/* ---- requests: the admin side ------------------------------------------- */

/** Admin: the whole inbox, newest activity first. */
export function useSupportInbox() {
  const session = useSessionStore()
  return useQuery({
    queryKey: supportKeys.inbox(),
    enabled: computed(() => session.isAdmin),
    queryFn: async (): Promise<SupportRequest[]> => {
      const { data, error } = await db
        .from('support_requests')
        .select(REQUEST_COLUMNS)
        .order('updated_at', { ascending: false })
        .limit(500)
      if (error) throw error
      return (data ?? []) as SupportRequest[]
    },
    staleTime: 30_000,
  })
}

/**
 * Admin: how many questions are waiting — the badge on the Admin nav item.
 * Gated on isAdmin so a rep's shell never issues it (the policy would return
 * only their own rows, but the request is still wasted).
 */
export function useOpenSupportCount() {
  const session = useSessionStore()
  return useQuery({
    queryKey: supportKeys.openCount(),
    enabled: computed(() => session.isSignedIn && session.isAdmin),
    queryFn: async (): Promise<number> => {
      const { count, error } = await db
        .from('support_requests')
        .select('id', { count: 'exact', head: true })
        .eq('status', 'open')
      if (error) throw error
      return count ?? 0
    },
    staleTime: 60_000,
    refetchInterval: 5 * 60_000,
  })
}
