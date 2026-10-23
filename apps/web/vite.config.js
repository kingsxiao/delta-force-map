import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 多端 monorepo：本文件所在的 apps/web 即 vite root（npm 脚本 cd 进来再跑）。
// 静态目录只用一个且保持默认：publicDir = 'public'（dev 于 / 下 serve，build 原样拷入 dist 根）。
// 不要把 publicDir 指到 'assets'：Vite 的静态目录仅 publicDir 一个，指向 assets 会使 public/ 全部失效。
// 仓库根 assets/ 原图为制作期留档，运行时不引用。
// @shared → 仓库根 shared/：网页端 / Node 后端 / iOS（Swift 同口径移植）共用的
// 纯函数域逻辑（sellEta / marketMeta / liveChannel）与接口契约。
export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@shared': fileURLToPath(new URL('../../shared', import.meta.url)),
    },
  },
  server: {
    // 本地 dev 的账号 API 由 vite 代理转发到同源部署服务（npm run serve，
    // 默认 8080）：/api/* 与部署形态一致走同源相对路径，生产构建不受影响。
    // serve 没开时登录页如实报「连不上服务器」，行情等匿名功能照常。
    proxy: {
      '/api': 'http://127.0.0.1:8080',
    },
  },
})
