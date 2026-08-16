<script setup lang="ts">
import { onErrorCaptured, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import AppShell from '@/components/AppShell.vue'
import AppButton from '@/components/ui/AppButton.vue'

const route = useRoute()

/**
 * Last-resort error boundary.
 *
 * Every data path already handles its own failure through AsyncState, so this
 * only catches what those cannot: an exception thrown during render. Without
 * it Vue unmounts the whole tree and the rep is left on a blank white screen
 * with no way back — the worst possible failure mode for someone standing in
 * a dealer's store, and indistinguishable from the app being down.
 *
 * Deliberately does not swallow the error: it is re-thrown to the console via
 * console.error so it still reaches whatever is watching, and returning false
 * only stops it from propagating further up (there is nothing above this).
 */
const renderError = ref<Error | null>(null)

onErrorCaptured((err) => {
  renderError.value = err instanceof Error ? err : new Error(String(err))
  console.error('[render error]', err)
  return false
})

// A navigation is the cheapest recovery there is, and the most likely thing
// the rep tries next. Clear on route change so a bad account page doesn't
// pin the error screen over the rest of the app.
watch(() => route.fullPath, () => (renderError.value = null))

/**
 * A hard navigation, not a router push: whatever wedged the render may still
 * be in the component tree, and a full reload is the one recovery that cannot
 * fail the same way twice.
 */
function reload() {
  window.location.assign('/')
}
</script>

<template>
  <div
    v-if="renderError"
    class="bg-canvas grid min-h-svh place-items-center px-6 text-center"
  >
    <div class="max-w-sm">
      <p class="font-label text-accent text-xs font-semibold tracking-[0.24em] uppercase">
        Something broke
      </p>
      <h1 class="u-display text-ink mt-2 text-3xl">This screen didn't load</h1>
      <p class="text-ink-2 mt-3 text-[15px] leading-relaxed">
        Nothing you did caused this and nothing you saved is lost. Try again,
        or head back to the overview.
      </p>
      <div class="mt-6 flex flex-col gap-2">
        <AppButton variant="primary" block @click="renderError = null">
          Try again
        </AppButton>
        <AppButton variant="secondary" block @click="reload">
          Back to overview
        </AppButton>
      </div>
    </div>
  </div>

  <!-- Public routes (login, reset, 404) render full-bleed; everything else is
       chrome-wrapped. -->
  <RouterView v-else-if="route.meta.public" />
  <AppShell v-else>
    <RouterView />
  </AppShell>
</template>
