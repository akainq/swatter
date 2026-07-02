import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: Number(process.env.PORT) || 5173,
    // dev: cookie-сессии same-origin через прокси к Phoenix (ADR-0007)
    proxy: {
      '/api': 'http://127.0.0.1:4000',
    },
  },
})
