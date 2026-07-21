import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// `base: './'` keeps asset URLs relative so the built index.html resolves its
// assets correctly under the `kairos://dashboard/` origin (served by the host's
// WKURLSchemeHandler). Dev (HMR) is at http://localhost:5173. `@` is the shadcn
// path alias.
export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'src') },
  },
  server: { port: 5173 },
})
