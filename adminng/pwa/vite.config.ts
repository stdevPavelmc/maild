import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

// AdminNG PWA — served by the `adminng` (nginx) service, same-origin with the
// API behind the /api/v1/ proxy (see nginx/default.conf). The service worker
// caches the static shell only; every API call is NetworkOnly, so mutations can
// never happen offline (adminng/doc/technical-draft.md §6.5).
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icon.svg'],
      manifest: {
        name: 'MailD AdminNG',
        short_name: 'AdminNG',
        description: 'MailD mailserver administration (PWA)',
        theme_color: '#0f172a',
        background_color: '#0f172a',
        display: 'standalone',
        start_url: '/',
        icons: [
          {
            src: 'icon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any',
          },
        ],
      },
      workbox: {
        navigateFallback: '/index.html',
        runtimeCaching: [
          {
            // No offline mutations, ever: never cache API traffic.
            urlPattern: /\/api\/v1\/.*/,
            handler: 'NetworkOnly',
          },
        ],
      },
    }),
  ],
  server: {
    port: 5173,
    // Local `npm run dev` talks to the api container (or a local uvicorn).
    proxy: {
      '/api': { target: 'http://localhost:8083', changeOrigin: true },
    },
  },
  build: { outDir: 'dist', sourcemap: false },
})
