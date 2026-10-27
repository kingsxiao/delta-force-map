import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './assets/styles/base.css'
import './assets/styles/motion.css' // 动效工具层（必须在 base.css 之后：引用其令牌）

createApp(App).use(router).mount('#app')
