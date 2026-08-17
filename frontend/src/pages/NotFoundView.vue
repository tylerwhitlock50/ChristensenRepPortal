<script setup lang="ts">
import AppButton from '@/components/ui/AppButton.vue'
</script>

<template>
  <div class="bg-canvas grid min-h-svh place-items-center px-4 text-center">
    <div>
      <p class="font-label text-accent text-xs font-semibold tracking-[0.24em] uppercase">
        404
      </p>
      <h1 class="u-display text-ink mt-2 text-4xl">
        That page doesn't exist
      </h1>
      <!-- 'overview', not 'today': /today is gated on feature.recommendations
           and ships disabled, so this button both bounced through the guard
           and named a page most reps have never seen. -->
      <RouterLink :to="{ name: 'overview' }" class="mt-6 inline-block">
        <AppButton variant="secondary">Back to overview</AppButton>
      </RouterLink>
    </div>
  </div>
</template>
