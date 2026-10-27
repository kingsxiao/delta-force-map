// imgReady.js — 远端图标加载态事件处理（三页共享，口径见 MOTION.md §4 / motion.css「图片占位」段）
// imgReady：img load 后给最近的 .a-icw 容器（无容器则给 img 自身）挂 .ld——
// 占位底让位、图片淡入；
// hideImg：加载失败隐藏 img，容器占位底留作「无图」位（不再空洞 + 孤零零的品级角标）。
export const imgReady = (e) => { (e.target.closest('.a-icw') || e.target).classList.add('ld') }

export const hideImg = (e) => { e.target.style.display = 'none' }
