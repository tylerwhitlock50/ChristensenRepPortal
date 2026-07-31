<script setup lang="ts">
import { useRoute } from 'vue-router'
import AppShell from '@/components/AppShell.vue'

const route = useRoute()
</script>

<template>
  <!-- Public routes (login, 404) render full-bleed; everything else is chrome-wrapped. -->
  <RouterView v-if="route.meta.public" />
  <AppShell v-else>
    <RouterView />
  </AppShell>
</template>
