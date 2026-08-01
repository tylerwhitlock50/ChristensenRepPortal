<script setup lang="ts">
import { computed, ref, useId } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useCreateTask, type Task } from '@/composables/useTasks'

const props = withDefaults(
  defineProps<{
    /** Attaches the follow-up to an account when added from that account. */
    customerKey?: string | null
    placeholder?: string
    /** Hide the date box until the rep asks for it — most adds don't need one. */
    withDueDate?: boolean
  }>(),
  {
    customerKey: null,
    placeholder: 'Add a follow-up…',
    withDueDate: true,
  },
)

const emit = defineEmits<{ added: [task: Task] }>()

const uid = useId()
const title = ref('')
const dueDate = ref('')
const showDate = ref(false)
const errorMessage = ref('')

const create = useCreateTask()
const canSubmit = computed(() => title.value.trim().length > 0)

function clearDueDate() {
  dueDate.value = ''
  showDate.value = false
}

async function submit() {
  if (!canSubmit.value || create.isPending.value) return
  errorMessage.value = ''
  try {
    const task = await create.mutateAsync({
      title: title.value,
      dueDate: dueDate.value || null,
      customerKey: props.customerKey,
    })
    title.value = ''
    dueDate.value = ''
    showDate.value = false
    emit('added', task)
  } catch (e) {
    errorMessage.value = (e as Error).message || 'Could not add that.'
  }
}
</script>

<template>
  <!-- Enter submits: the form element does that for free, and it's the only
       thing a rep one-handed on a phone will reliably hit. -->
  <form @submit.prevent="submit">
    <div class="flex flex-wrap items-center gap-2">
      <label :for="`${uid}-title`" class="sr-only">Follow-up</label>
      <input
        :id="`${uid}-title`"
        v-model="title"
        type="text"
        enterkeyhint="done"
        autocapitalize="sentences"
        :placeholder="placeholder"
        class="tap-target min-w-0 flex-1 rounded-[2px] border border-line-2 bg-surface px-3 py-2 text-base outline-none focus:border-brand"
      />

      <button
        v-if="withDueDate && !showDate"
        type="button"
        class="tap-target shrink-0 rounded-[2px] border border-line-2 bg-surface px-3 text-sm font-medium text-ink-2"
        @click="showDate = true"
      >
        Due date
      </button>

      <AppButton type="submit" :disabled="!canSubmit" :loading="create.isPending.value">
        Add
      </AppButton>
    </div>

    <div v-if="withDueDate && showDate" class="mt-2 flex items-center gap-2">
      <label :for="`${uid}-due`" class="text-sm font-medium text-ink-2">
        Due
      </label>
      <input
        :id="`${uid}-due`"
        v-model="dueDate"
        type="date"
        class="tap-target min-w-0 flex-1 rounded-[2px] border border-line-2 bg-surface px-3 py-2 text-base outline-none focus:border-brand"
      />
      <button
        type="button"
        class="tap-target shrink-0 px-2 text-sm font-medium text-muted"
        @click="clearDueDate"
      >
        Clear
      </button>
    </div>

    <p v-if="errorMessage" role="alert" class="mt-2 text-sm text-danger">
      {{ errorMessage }}
    </p>
  </form>
</template>
