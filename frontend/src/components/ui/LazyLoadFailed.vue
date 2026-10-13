<script setup lang="ts">
import { useOnline } from '@vueuse/core'
import AppButton from '@/components/ui/AppButton.vue'

/**
 * What an in-page lazy piece (the visit survey, the photo picker, the
 * contact form) shows when its code did not download. defineAsyncComponent
 * renders this as its errorComponent; App.vue keeps the failure from
 * replacing the whole screen, and Vue tries the download again the next
 * time the piece mounts.
 *
 * Offline, the honest answer is that this part was never saved to the
 * phone. Online, the likeliest cause is a deploy since the tab was opened
 * (the old chunk is gone), which only a reload fixes — a visit draft
 * lives in IndexedDB and survives it.
 */
defineProps<{ error?: unknown }>()

const online = useOnline()

function reload() {
  window.location.reload()
}
</script>

<template>
  <div role="status" class="text-ink-2 text-sm">
    <p v-if="!online">
      This part hasn't been saved to this phone yet, so it needs a signal to
      open. It will work once you're back online.
    </p>
    <template v-else>
      <p>This part didn't load. Reloading the app usually fixes it.</p>
      <AppButton class="mt-2" @click="reload">Reload the app</AppButton>
    </template>
  </div>
</template>
