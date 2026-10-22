#!/bin/bash
# ios-wf.sh — iOS 视觉验收流水线的确定性截图脚本（供工作流 world.run 调用）
# 用法：ios-wf.sh shoot <输出目录>
# 行为：把 xcodebuild 产物安装到 iPhone 18 Pro 模拟器，逐 Tab 用 -startTab 启动并截图。
#       每张截图做「疑似白屏」体检（PNG 过小 = 没渲染好），自动重拍一次。
# 输出：成功打印「OK <目录> 5张」；异常以非零退出并打印「ERROR/WARN <原因>」。
set -uo pipefail

UDID="0B441A6B-1F89-414E-8931-A67060F6929D"
BUNDLE="com.kingsxiao.deltaforce"
CMD="${1:-}"
DIR="${2:-}"
MIN_BYTES=100000 # 实测：白屏约 70KB，正常内容 ≥200KB

app_path() {
  ls -d "$HOME"/Library/Developer/Xcode/DerivedData/DeltaForce-*/Build/Products/Debug-iphonesimulator/DeltaForce.app 2>/dev/null | head -1
}

shot_one() { # <tab> <out.png> <等待秒数>
  local tab="$1" out="$2" wait="$3"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" "-startTab" "$tab" >/dev/null 2>&1 || { echo "ERROR 启动失败 tab=$tab"; return 1; }
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$out" >/dev/null 2>&1 || { echo "ERROR 截图失败 tab=$tab"; return 1; }
}

fsize() { stat -f%z "$1" 2>/dev/null || echo 0; }

shoot() {
  local out="$1" app first=1 tab f n
  app="$(app_path)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "ERROR 找不到构建产物 DeltaForce.app（先跑 xcodebuild）"
    exit 1
  fi
  # 模拟器没开机就开机，并等启动完成
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$app" || { echo "ERROR 安装失败：$app"; exit 1; }
  mkdir -p "$out"
  for tab in ammo radar ttk settings; do
    f="$out/$tab.png"
    # 冷启动首拍渲染最慢，多等
    if ((first)); then
      shot_one "$tab" "$f" 12 || exit 1
      first=0
    else
      shot_one "$tab" "$f" 7 || exit 1
    fi
    if [[ "$(fsize "$f")" -lt $MIN_BYTES ]]; then
      echo "WARN tab=$tab 疑似白屏（$(fsize "$f")B），重拍"
      shot_one "$tab" "$f" 14 || exit 1
      if [[ "$(fsize "$f")" -lt $MIN_BYTES ]]; then
        echo "WARN tab=$tab 重拍后仍偏小（$(fsize "$f")B），可能是真空态页，留待验收员判断"
      fi
    fi
  done
  n="$(ls "$out" | grep -c '\.png$')"
  if [[ "$n" -ne 5 ]]; then
    echo "ERROR 截图数量不对：$n/5（目录 $out）"
    exit 1
  fi
  echo "OK $out 5张"
}

case "$CMD" in
  shoot) shoot "$DIR" ;;
  *) echo "用法：$0 shoot <输出目录>"; exit 2 ;;
esac
