<script setup lang="ts">
import AppButton from '@/components/ui/AppButton.vue'
</script>

<template>
  <div class="grid min-h-svh place-items-center px-4 text-center">
    <div>
      <p class="text-sm font-medium text-zinc-500">404</p>
      <h1 class="mt-1 text-xl font-semibold tracking-tight text-zinc-900">
        That page doesn't exist
      </h1>
      <RouterLink :to="{ name: 'today' }" class="mt-4 inline-block">
        <AppButton>Back to today</AppButton>
      </RouterLink>
    </div>
  </div>
</template>
