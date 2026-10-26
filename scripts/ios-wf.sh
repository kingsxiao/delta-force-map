#!/bin/bash
# ios-wf.sh — iOS 视觉验收流水线的确定性截图脚本（供工作流 world.run 调用）
# 用法：
#   ios-wf.sh shoot <输出目录>          # 全量基线：5 Tab + 账号页 + 3 个详情 + 4 个滚动到底态
#   ios-wf.sh one <out.png> <秒> [启动参数…]  # 任意单态补拍（如 -startTab settings -openAccount）
# 行为：把 xcodebuild 产物安装到 iPhone 18 Pro 模拟器，按状态表用启动参数直达并截图。
#       深链参数（-openDetailFirst 等）由各 View 的 UI 巡检钩子消费（生产无此参数，行为不变）。
#       每张截图做「疑似白屏」体检（PNG 过小 = 没渲染好），自动重拍一次。
# 输出：成功打印「OK <目录> N张」；异常以非零退出并打印「ERROR/WARN <原因>」。
set -uo pipefail

UDID="0B441A6B-1F89-414E-8931-A67060F6929D"
BUNDLE="com.kingsxiao.deltaforce"
CMD="${1:-}"
MIN_BYTES=100000 # 实实测：白屏约 70KB，正常内容 ≥200KB

# 状态表：<文件名> <等待秒> <启动参数…>（首行冷启动等最久；详情/滚动类要等数据+布局，≥12s）
STATES=(
  "ammo 12 -startTab ammo"
  "radar 8 -startTab radar"
  "craft 8 -startTab craft"
  "ttk 8 -startTab ttk"
  "settings 8 -startTab settings"
  "account 9 -startTab settings -openAccount"
  "ammo-detail 12 -startTab ammo -openDetailFirst"
  "playbook 9 -startTab ammo -openPlaybook"
  "craft-detail 12 -startTab craft -openCraftFirst"
  "gun-detail 9 -startTab ttk -openGunFirst"
  "ammo-scrollend 12 -startTab ammo -wfScrollEnd"
  "radar-scrollend 12 -startTab radar -wfScrollEnd"
  "craft-scrollend 12 -startTab craft -wfScrollEnd"
  "ttk-scrollend 10 -startTab ttk -wfScrollEnd"
)

app_path() {
  # -t 按修改时间取最新：历史会话可能用过自定义 -derivedDataPath（如 DeltaForce-ttkfix），
  # 留下的旧产物不该被选中
  ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/DeltaForce-*/Build/Products/Debug-iphonesimulator/DeltaForce.app 2>/dev/null | head -1
}

# 模拟器开机 + 安装当前构建产物（shoot/one 共用；失败即退出）
ensure_env() {
  local app
  app="$(app_path)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "ERROR 找不到构建产物 DeltaForce.app（先跑 xcodebuild）"
    exit 1
  fi
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$app" || { echo "ERROR 安装失败：$app"; exit 1; }
}

shot_one() { # <out.png> <等待秒数> [启动参数…]
  local out="$1" wait="$2"; shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null 2>&1 || { echo "ERROR 启动失败：$*"; return 1; }
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$out" >/dev/null 2>&1 || { echo "ERROR 截图失败：$*"; return 1; }
}

fsize() { stat -f%z "$1" 2>/dev/null || echo 0; }

# 单态拍摄 + 白屏重拍（shoot 状态循环体；返回 0/1）
shoot_state() { # <dir> <状态行>
  local dir="$1" line="$2" name wait args f
  read -r name wait args <<< "$line"
  f="$dir/$name.png"
  shot_one "$f" "$wait" $args || return 1
  if [[ "$(fsize "$f")" -lt $MIN_BYTES ]]; then
    echo "WARN $name 疑似白屏（$(fsize "$f")B），重拍"
    shot_one "$f" 14 $args || return 1
    if [[ "$(fsize "$f")" -lt $MIN_BYTES ]]; then
      echo "WARN $name 重拍后仍偏小（$(fsize "$f")B），可能是真空态页，留待验收员判断"
    fi
  fi
}

shoot() {
  local out="$1" line name miss=0
  ensure_env
  mkdir -p "$out"
  for line in "${STATES[@]}"; do
    shoot_state "$out" "$line" || exit 1
  done
  # 按名校验：每个状态的截图必须存在且非空；目录里允许有 one 补拍的额外文件
  for line in "${STATES[@]}"; do
    read -r name _ <<< "$line"
    if [[ ! -s "$out/$name.png" ]]; then
      echo "ERROR 缺少截图 $out/$name.png"
      miss=1
    fi
  done
  if ((miss)); then exit 1; fi
  echo "OK $out ${#STATES[@]}张（按名校验通过）"
}

one() { # <out.png> <秒> [启动参数…]
  local out="$1" wait="$2"; shift 2
  ensure_env
  mkdir -p "$(dirname "$out")"
  shot_one "$out" "$wait" "$@" || exit 1
  if [[ "$(fsize "$out")" -lt $MIN_BYTES ]]; then
    echo "WARN ${out} 疑似白屏（$(fsize "$out")B），已重拍一次"
    shot_one "$out" 14 "$@" || exit 1
  fi
  echo "OK ${out}（$(fsize "$out")B）"
}

case "$CMD" in
  shoot) shoot "$2" ;;
  one) one "$2" "$3" "${@:4}" ;;
  *) echo "用法：$0 shoot <输出目录> | one <out.png> <秒> [启动参数…]"; exit 2 ;;
esac
