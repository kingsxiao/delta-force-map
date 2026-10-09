import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 静态目录只用一个且保持默认：publicDir = 'public'（dev 于 / 下 serve，build 原样拷入 dist 根）。
// 不要把 publicDir 指到 'assets'：Vite 的静态目录仅 publicDir 一个，指向 assets 会使 public/ 全部失效。
// assets/ 原图不作静态目录，一律模块 import 引用——仅被 import 的文件才会进 dist。
export default defineConfig({
  plugins: [vue()],
})
