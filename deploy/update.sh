#!/usr/bin/env bash
# update.sh — 服务器上一键更新：拉代码 → 装依赖 → 构建 → 重启服务
# 用法：在仓库任意位置执行 ./deploy/update.sh（需要 sudo 权限重启 systemd 服务）
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)/.."
echo "==> 仓库：$(pwd)"

echo "==> 拉取最新代码"
# serve 常驻进程会持续重写三个被 git 跟踪的行情快照（deploy/aliyun.md「数据写入」），
# 不先还原会常态性挡住 --ff-only；数据由服务下一轮重新生成，不会丢
git checkout -- apps/web/public/ammo/market.json apps/web/public/market/radar.json apps/web/public/craft/craft.json
git pull --ff-only

echo "==> 安装依赖（锁定版本）"
npm ci

echo "==> 构建"
npm run build

echo "==> 同步 systemd 单元（ExecStart 路径随 monorepo 重构变更过，这里自动对齐）"
if ! sudo cmp -s deploy/delta-force-map.service /etc/systemd/system/delta-force-map.service 2>/dev/null; then
  sudo cp deploy/delta-force-map.service /etc/systemd/system/delta-force-map.service
  sudo systemctl daemon-reload
fi

echo "==> 重启服务"
sudo systemctl restart delta-force-map

sleep 2
systemctl is-active delta-force-map && echo "==> 完成：$(curl -s http://127.0.0.1:${PORT:-8080}/health)"
