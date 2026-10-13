<script setup lang="ts">
import { defineAsyncComponent, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useQueryClient } from '@tanstack/vue-query'
import { useSessionStore } from '@/stores/session'
import { installRecentAccountsTracking } from '@/composables/useRecentAccounts'

/**
 * Search from every screen: a dealer, an order or a product, from the
 * magnifier in the header (or "/" at a desk).
 *
 * This is only the button. The sheet (GlobalSearchSheet.vue) and the three
 * searches behind it load on first use, so the header costs the entry
 * chunk a few hundred bytes, not the account, lookup and ATS composables.
 * Pressing the button warms the chunk before the click lands.
 *
 * It also starts recording which dealers the rep opens (useRecentAccounts),
 * which is what the sheet shows before anything is typed.
 */

const router = useRouter()
const queryClient = useQueryClient()
const session = useSessionStore()

installRecentAccountsTracking(router, queryClient, () => session.user?.id ?? null)

const loadSheet = () => import('@/components/GlobalSearchSheet.vue')
const GlobalSearchSheet = defineAsyncComponent(loadSheet)

const open = ref(false)
const trigger = ref<HTMLButtonElement | null>(null)

function warm() {
  void loadSheet()
}

function openSearch() {
  open.value = true
}

async function closeSearch(restoreFocus: boolean) {
  open.value = false
  if (restoreFocus) {
    await nextTick()
    trigger.value?.focus()
  }
}

/* "/" opens it at a desk, the way most search boxes do — unless the rep is
   already typing somewhere else. */
function onGlobalKeydown(e: KeyboardEvent) {
  if (open.value || session.isOrderEntry) return
  if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return
  const t = e.target as HTMLElement | null
  if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return
  e.preventDefault()
  openSearch()
}
onMounted(() => document.addEventListener('keydown', onGlobalKeydown))
onBeforeUnmount(() => document.removeEventListener('keydown', onGlobalKeydown))
</script>

<template>
  <!-- Not for the order-entry role: its book is empty by design (see the
       nav in AppShell), so every search would come back blank. -->
  <button
    v-if="!session.isOrderEntry"
    ref="trigger"
    type="button"
    class="tap-target grid min-w-11 place-items-center text-[#C9C5BB] hover:text-canvas"
    aria-label="Search dealers, orders and products"
    title="Search (/)"
    aria-haspopup="dialog"
    :aria-expanded="open"
    @pointerdown="warm"
    @focus="warm"
    @click="openSearch"
  >
    <svg
      class="size-6"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="11" cy="11" r="7" />
      <path d="M20 20l-3.5-3.5" />
    </svg>
  </button>

  <GlobalSearchSheet v-if="open" @close="closeSearch" />
</template>
