# 阿里云 ECS 部署（实时模式）

目标：ECS 上常驻 `npm run serve` 进程——静态站 + 实时行情抓取 + SSE 推送，
浏览器访问即实时（信号分钟级滚动，页面端到端 ≤ 源分钟粒度 + 60s + 5s）。
单进程零依赖（只要 Node ≥ 20.19），1 核 1G 的小机器即可跑。

## 一、准备 ECS

- 系统：Ubuntu 22.04 / 24.04（CentOS 步骤类似）
- **安全组**：控制台 → ECS → 安全组 → 入方向添加规则，放行要用到的端口：
  - 快速路径：`8080/tcp`（IP 直连即可用，本文默认）
  - 域名路径：`80/tcp` + `443/tcp`（走 nginx 反代）
- 大陆地域 + 域名 + 80/443 需要 **ICP 备案**（阿里云控制台有备案流程，约 1–2 周）；
  不想备案有两个选择：直接用 `http://<公网IP>:8080` 访问（完全可用，SSE 同样工作），
  或用香港地域 ECS。

## 二、装 Node 20（国内网络友好，系统级安装）

```bash
# npmmirror 镜像直装到 /usr/local（全局可用，systemd / 所有用户都能找到）
cd /tmp
NODE_VER=v20.19.0        # 任选 ≥ v20.19 的最新 20.x；ARM 机型换 linux-arm64
wget https://npmmirror.com/mirrors/node/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz
sudo tar -xJf node-${NODE_VER}-linux-x64.tar.xz -C /usr/local --strip-components=1
node -v                  # ≥ v20.19

# npm 走国内镜像（装依赖快很多）
npm config set registry https://registry.npmmirror.com
```

## 三、部署代码 + 构建

```bash
sudo useradd -r -m -d /opt/delta-force-map -s /usr/sbin/nologin dfmap
sudo -u dfmap git clone https://github.com/kingsxiao/delta-force-map.git /opt/delta-force-map
cd /opt/delta-force-map
sudo -u dfmap npm ci
sudo -u dfmap npm run build
# build 不打外网：dist 用仓库内快照；serve 启动后抓取循环会自动刷新数据
```

## 四、systemd 常驻

```bash
sudo cp deploy/delta-force-map.service /etc/systemd/system/
# 确认单元内 WorkingDirectory=/opt/delta-force-map、User=dfmap 与上面一致
sudo systemctl daemon-reload
sudo systemctl enable --now delta-force-map
journalctl -u delta-force-map -f        # 看到 [moligod] version ... 即抓取循环已在跑
curl http://127.0.0.1:8080/health       # {"ok":true,...}
```

浏览器打开 `http://<公网IP>:8080/#/ammo`，页头出现「实时推送」即全链路打通
（同源 SSE，无需任何前端配置）。

## 五、（可选）域名 + https

```bash
sudo apt install -y nginx certbot python3-certbot-nginx
sudo cp deploy/nginx.conf.example /etc/nginx/sites-available/delta-force-map
sudo ln -s /etc/nginx/sites-available/delta-force-map /etc/nginx/sites-enabled/
# 编辑 server_name 为你的域名（DNS A 记录先指到 ECS 公网 IP）
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d your.domain.com    # 自动配 443 + 续期
```

nginx 配置已处理 SSE 关键点（`proxy_buffering off` + 长读超时；服务端也发了
`X-Accel-Buffering: no` 双保险），https 下同源 SSE 照常工作。

## 六、日常更新（一键）

代码推到 GitHub 后，服务器上执行：

```bash
/opt/delta-force-map/deploy/update.sh    # 拉代码 → npm ci → build → 重启服务
```

## 运维要点

- **不要同时跑第二个写盘者**（ammo:live / ammo:monitor / 手动 ammo:fetch），
  serve 进程内已包含等价的抓取循环。
- 上游故障自动回落 kkrb（小时级），恢复后自动切回 moligod；两源全挂指数退避。
- 日志：`journalctl -u delta-force-map -f`；状态：`/health` 的
  `consecutiveFailures` 持续 >0 说明上游或网络有问题。
- 磁盘占用极小：站点几 MB + `data/ammo/` 留档（超 7 天 / 1000 份自动清理）。
- 内存占用：单进程 ~100MB 内，1G 机型足够。
