#!/usr/bin/env bash
# deploy/ios-archive.sh — iOS 打包：Release 归档 + IPA 导出 + 体积报告
#
# 用法（仓库根执行）：
#   npm run ios:archive                          # 默认：未签名 Release 模拟器构建 + 体积报告（本地体积检查，无需签名）
#   bash deploy/ios-archive.sh --ipa --team <开发者团队ID> [--method development|app-store-connect]
#                                                # 真机归档 + 导出 IPA（TestFlight 用 --method app-store-connect）
#   可选 --refresh-data：打包前先 npm run export:ios 重导 TTK 数据
#
# 说明：
# - 工程由 project.yml 生成，脚本每次先跑 xcodegen generate，保证 xcodeproj 与 yml 一致。
# - Release 体积优化见 project.yml settings.configs.Release：-Osize + Thin LTO + 归档期符号剥离
#   （STRIP_STYLE=all 只去二进制符号，dSYM 在 xcarchive 里，崩溃符号化不受影响）。
# - 未签名模式只构建模拟器目标做体积检查；真机/TestFlight 必须走 --ipa（需要开发者团队）。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=sim TEAM='' METHOD=development REFRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa) MODE=ipa ;;
    --team) TEAM="${2:?--team 需要团队ID}"; shift ;;
    --method) METHOD="${2:?--method 需要 development 或 app-store-connect}"; shift ;;
    --refresh-data) REFRESH=1 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$REFRESH" == 1 ]]; then
  echo "== 重导 TTK 数据 =="
  npm run export:ios
fi

echo "== 重新生成 Xcode 工程 =="
(cd apps/ios && xcodegen generate)

OUT=apps/ios/build
rm -rf "$OUT"

report() {
  local app="$1"
  echo "==================== 体积报告 ===================="
  du -sh "$app"
  if [[ -d "$app" ]]; then
    echo "--- 内部明细（降序）---"
    du -sh "$app"/* | sort -rh
    if [[ -f "$app/DeltaForce" ]]; then
      echo "二进制架构: $(lipo -info "$app/DeltaForce" 2>/dev/null || echo '—')"
    fi
  fi
  echo "=================================================="
}

if [[ "$MODE" == sim ]]; then
  echo "== 未签名 Release 构建（模拟器目标，体积检查）=="
  xcodebuild -project apps/ios/DeltaForce.xcodeproj -scheme DeltaForce \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUT/dd" build CODE_SIGNING_ALLOWED=NO
  report "$OUT/dd/Build/Products/Release-iphonesimulator/DeltaForce.app"
  echo "完成：未签名 Release 包。真机 / TestFlight 请用 --ipa --team <团队ID>。"
  exit 0
fi

if [[ -z "$TEAM" ]]; then
  echo "错误：--ipa 需要 --team <开发者团队ID>（Apple Developer 后台 Membership 页可查）" >&2
  exit 2
fi

echo "== Release 真机归档（团队 $TEAM）=="
xcodebuild -project apps/ios/DeltaForce.xcodeproj -scheme DeltaForce \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$OUT/DeltaForce.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>stripSwiftSymbols</key><true/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "== 导出 IPA（method=${METHOD}）=="
xcodebuild -exportArchive -archivePath "$OUT/DeltaForce.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/ipa"

IPA=$(ls "$OUT/ipa/"*.ipa 2>/dev/null | head -1)
if [[ -n "$IPA" ]]; then
  report "$IPA"
  echo "完成：IPA 在 $OUT/ipa/；dSYM 在 $OUT/DeltaForce.xcarchive/dSYMs/（提交崩溃符号时用）。"
else
  echo "警告：导出目录未见 IPA，请检查上方 xcodebuild 输出" >&2
  exit 1
fi
