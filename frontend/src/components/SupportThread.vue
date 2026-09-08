<script setup lang="ts">
import { computed, ref } from 'vue'
import { useSessionStore } from '@/stores/session'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { shortDate } from '@/lib/format'
import {
  usePostSupportMessage,
  useSetSupportStatus,
  useSupportThread,
  type SupportMessage,
  type SupportRequest,
} from '@/composables/useSupport'

/**
 * One support thread: the messages, a reply box, and solved / reopen.
 * Shared by the rep's Help page and the admin inbox — the only difference
 * is who "You" is, and that comes from the session.
 */
const props = defineProps<{
  request: SupportRequest
  /** Admin side: the requester's display name for their messages. */
  requesterName?: string
}>()

const session = useSessionStore()
const thread = useSupportThread(computed(() => props.request.id))
const post = usePostSupportMessage()
const setStatus = useSetSupportStatus()

const reply = ref('')
const error = ref('')

function who(m: SupportMessage): string {
  if (m.author_id === session.user?.id) return 'You'
  if (m.from_admin) return 'Support'
  return props.requesterName || 'Rep'
}

async function send() {
  error.value = ''
  try {
    await post.mutateAsync({ requestId: props.request.id, body: reply.value })
    reply.value = ''
  } catch (e) {
    error.value = (e as Error).message || 'Could not send that.'
  }
}

async function mark(status: 'closed' | 'open') {
  error.value = ''
  try {
    await setStatus.mutateAsync({ requestId: props.request.id, status })
  } catch (e) {
    error.value = (e as Error).message || 'Could not update that.'
  }
}
</script>

<template>
  <div>
    <AsyncState
      :loading="thread.isPending.value"
      :error="thread.error.value"
      :empty="(thread.data.value ?? []).length === 0"
      empty-title="No messages"
      :rows="2"
      @retry="thread.refetch()"
    >
      <ol class="space-y-3">
        <li
          v-for="m in thread.data.value"
          :key="m.id"
          class="border-l-[3px] pl-3"
          :class="m.from_admin ? 'border-accent' : 'border-line-2'"
        >
          <p class="text-muted text-[13px]">
            <span class="text-ink font-semibold">{{ who(m) }}</span>
            · {{ shortDate(m.created_at) }}
          </p>
          <p class="text-ink-2 mt-1 text-[15px] leading-relaxed whitespace-pre-wrap">{{ m.body }}</p>
        </li>
      </ol>
    </AsyncState>

    <form v-if="session.canWrite" class="mt-4 space-y-3" @submit.prevent="send">
      <label class="block">
        <span class="sr-only">Reply</span>
        <textarea
          v-model="reply"
          class="field min-h-24"
          maxlength="8000"
          :placeholder="request.status === 'closed' ? 'Add to this thread (reopens it)…' : 'Reply…'"
        />
      </label>
      <p v-if="error" role="alert" class="text-danger text-sm font-medium">{{ error }}</p>
      <div class="flex flex-wrap gap-2">
        <AppButton
          type="submit"
          variant="secondary"
          :loading="post.isPending.value"
          :disabled="!reply.trim()"
        >
          Send
        </AppButton>
        <AppButton
          v-if="request.status !== 'closed'"
          variant="ghost"
          :loading="setStatus.isPending.value"
          @click="mark('closed')"
        >
          Mark solved
        </AppButton>
        <AppButton
          v-else
          variant="ghost"
          :loading="setStatus.isPending.value"
          @click="mark('open')"
        >
          Reopen
        </AppButton>
      </div>
    </form>
  </div>
</template>
