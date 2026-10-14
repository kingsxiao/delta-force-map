#!/usr/bin/env bash
# update.sh — 服务器上一键更新：拉代码 → 装依赖 → 构建 → 重启服务
# 用法：在仓库任意位置执行 ./deploy/update.sh（需要 sudo 权限重启 systemd 服务）
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)/.."
echo "==> 仓库：$(pwd)"

echo "==> 拉取最新代码"
git pull --ff-only

echo "==> 安装依赖（锁定版本）"
npm ci

echo "==> 构建"
npm run build

echo "==> 重启服务"
sudo systemctl restart delta-force-map

sleep 2
systemctl is-active delta-force-map && echo "==> 完成：$(curl -s http://127.0.0.1:${PORT:-8080}/health)"
