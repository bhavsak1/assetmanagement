import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // .env lives at the repo root, next to .env.example.
  envDir: '../..',
})
