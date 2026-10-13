/* ============================================================
   notify.mjs — macOS 系统通知（osascript），非 macOS 平台静默降级为控制台输出
   ============================================================ */
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
const execFileP = promisify(execFile)

const isMac = process.platform === 'darwin'

/** 转义 AppleScript 字符串里的双引号与反斜杠 */
const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')

/**
 * 发一条 macOS 通知（正文 ≤ 255 字符，超长自动截断）。
 * @param {{title:string, body:string, sound?:string}} opts
 */
export async function notify({ title, body, sound = 'Glass' }) {
  const text = body.length > 250 ? body.slice(0, 250) + '…' : body
  if (!isMac) {
    console.log(`[notify] ${title} | ${text}`)
    return
  }
  const script =
    `display notification "${esc(text)}" with title "${esc(title)}"` +
    (sound ? ` sound name "${esc(sound)}"` : '')
  try {
    await execFileP('osascript', ['-e', script])
  } catch (e) {
    console.error(`[notify] 发送失败: ${e.message}`)
  }
}
