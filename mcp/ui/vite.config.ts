import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// MailD MCP user page. Served by Django + WhiteNoise from the mcp image (mcp/Dockerfile copies
// dist/index.html, dist/assets/ and the public files into /app/ui-dist). Hashed assets under
// /assets/ are cached for ever; index.html is never cached (mcpcore/views.py:spa).
export default defineConfig({
  plugins: [react()],
  base: '/',
  build: { outDir: 'dist', assetsDir: 'assets', sourcemap: false },
  server: { proxy: { '/webapi': 'http://localhost:8085' } },
})
