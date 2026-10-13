import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'

/**
 * One id per deploy. The saved read cache is keyed to it (lib/queryPersist.ts)
 * so a phone never restores data shaped for an older build. Vercel provides
 * the commit; anywhere else a build stamp does the same job.
 */
const buildId = process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 12) || `local-${Date.now()}`

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue(), tailwindcss()],
  define: {
    __BUILD_ID__: JSON.stringify(buildId),
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
