import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    host: '0.0.0.0',
    port: 8080,
    // 端口被占用时直接失败并报错，不静默切换到其他端口（基线固定开发端口）
    strictPort: true
  },
  preview: {
    host: '0.0.0.0',
    port: 4173,
    strictPort: true
  },
  test: {
    globals: true,
    environment: 'jsdom'
  }
})
