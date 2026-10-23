# 阿里云 ECS 部署（实时模式 · 线上实况）

目标：ECS 上常驻 serve 进程——静态站 + 实时行情抓取 + SSE 推送，
浏览器访问即实时（信号分钟级滚动，页面端到端 ≤ 源分钟粒度 + 60s + 5s）。
单进程零依赖（只要 Node ≥ 20.19），1 核 1.8G 的小机器即可跑。

**本文档描述的是线上那台 ECS 的实际部署**（root 用户 + /root/delta-force-map + nvm Node），
与 `deploy/delta-force-map.service` 模板逐字节一致，改一处必须同步另一处
（update.sh 会用 cmp 比对单元文件，不一致时用模板覆盖）。

## 线上实况速查

| 项 | 值 |
| --- | --- |
| 机器 | 阿里云 ECS（iZ2vc7wesatjnsd7wpemj5Z），1.8G 内存 |
| 用户 / 目录 | root，仓库在 `/root/delta-force-map` |
| Node | nvm 安装：`/root/.nvm/versions/node/v24.15.0/bin/node` |
| 服务 | systemd：`delta-force-map.service`，监听 `0.0.0.0:8080` |
| 静态产物 | `apps/web/dist/`（monorepo：web 端在 `apps/web/`，另有 `apps/ios/`） |
| 数据写入 | 服务运行时持续刷新 `apps/web/public/ammo/market.json` 与 `apps/web/public/market/radar.json`（这两个文件的本地改动是正常现象，不要提交也不要还原后长时间搁置——还原后服务下一轮就会重写） |
| 健康检查 | `curl http://127.0.0.1:8080/health` → `{"ok":true,...}` |

## 一、准备 ECS（装机时一次性的）

- 系统：Alibaba Cloud Linux（其他发行版步骤类似）
- **安全组**：控制台 → ECS → 安全组 → 入方向放行：
  - 快速路径：`8080/tcp`（IP 直连即可用）
  - 域名路径：`80/tcp` + `443/tcp`（走 nginx 反代）
- 大陆地域 + 域名 + 80/443 需要 **ICP 备案**；不想备案可直接
  `http://<公网IP>:8080` 访问（SSE 同样工作），或用香港地域。

## 二、装 Node（nvm，用户级）

```bash
# nvm + 国内镜像
git clone https://gitee.com/mirrors/nvm.git ~/.nvm --depth=1
echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc
echo 'source "$NVM_DIR/nvm.sh"' >> ~/.bashrc
source ~/.bashrc
nvm install 24 && nvm alias default 24
node -v    # v24.15.0

# npm 走国内镜像（装依赖快很多）
npm config set registry https://registry.npmmirror.com
```

注意：systemd 不加载 nvm 环境，所以单元文件里用**绝对路径**的 node
并把 nvm bin 目录写进 `Environment=PATH`（见 deploy/delta-force-map.service）。
升级 Node 版本后必须同步改单元里的这两处 + daemon-reload。

## 三、部署代码 + 构建

```bash
git clone git@github.com:kingsxiao/delta-force-map.git /root/delta-force-map
cd /root/delta-force-map
npm ci
npm run build        # vite 构建到 apps/web/dist/
```

## 四、systemd 常驻

```bash
cp deploy/delta-force-map.service /etc/systemd/system/
# 模板已与实机一致（root + /root/delta-force-map + nvm 绝对路径），
# 换机器时改 WorkingDirectory / ExecStart / PATH 三处
systemctl daemon-reload
systemctl enable --now delta-force-map
journalctl -u delta-force-map -f     # 看到 [moligod] version ... 即抓取循环已在跑
curl http://127.0.0.1:8080/health    # {"ok":true,...}
```

浏览器打开 `http://<公网IP>:8080/#/ammo`，页头出现「实时推送」即全链路打通
（同源 SSE，无需任何前端配置）。

### 单元内的 OOM 防护（1.8G 小机器必备，勿删）

- `Environment=NODE_OPTIONS=--max-old-space-size=256`：限制 node 堆
- `OOMScoreAdjust=200`：内存吃紧时优先杀本服务而不是拖垮整机
- `Restart=always` + `RestartSec=5`：被 OOM 杀后 5 秒自动拉起

## 五、（可选）域名 + https

```bash
dnf install -y nginx certbot python3-certbot-nginx   # Ubuntu: apt install ...
cp deploy/nginx.conf.example /etc/nginx/conf.d/delta-force-map.conf
# 编辑 server_name 为你的域名（DNS A 记录先指到 ECS 公网 IP）
nginx -t && systemctl reload nginx
certbot --nginx -d your.domain.com    # 自动配 443 + 续期
```

nginx 配置已处理 SSE 关键点（`proxy_buffering off` + 长读超时；服务端也发了
`X-Accel-Buffering: no` 双保险），https 下同源 SSE 照常工作。

## 六、日常更新（一键）

代码推到 GitHub 后，服务器上执行：

```bash
/root/delta-force-map/deploy/update.sh
# 拉代码 → npm ci → build → cmp 校验并同步 systemd 单元 → 重启服务 → 健康检查
```

注意：`git pull --ff-only` 可能被服务运行时刷新的数据文件挡住
（`apps/web/public/ammo/market.json`、`apps/web/public/market/radar.json` 是被 git 跟踪的）。
真被挡住时先还原再重跑，数据由服务下一轮重新生成，不会丢：

```bash
git checkout -- apps/web/public/
/root/delta-force-map/deploy/update.sh
```

## 运维要点

- **不要同时跑第二个写盘者**（ammo:live / ammo:monitor / radar:monitor / 手动 fetch），
  serve 进程内已包含弹药 + 雷达两套抓取循环（雷达默认 10 分钟一轮，`--radar-interval N`
  或环境变量 `RADAR_INTERVAL_MIN` 可调）。
- 上游故障自动回落 kkrb（小时级），恢复后自动切回 moligod；两源全挂指数退避。
- 日志：`journalctl -u delta-force-map -f`（弹药 `[moligod]` / 雷达 `[radar]` 两路）；
  状态：`/health` 的 `consecutiveFailures` 持续 >0 说明上游或网络有问题。
- 磁盘占用极小：站点几 MB + `data/ammo/` 留档（超 7 天 / 1000 份自动清理）。
- 账号接口限速按 IP 计：nginx 反代形态下 X-Forwarded-For 才可信，需在服务启动参数加
  `--trust-proxy`（systemd 单元 `ExecStart=node server/server.mjs --trust-proxy`，改后
  `systemctl daemon-reload && systemctl restart delta-force-map`）；不加则按直连地址计，
  全部请求会算在 127.0.0.1 一个桶里（对单管理员自用影响小，但注册/登录配额会被共享）。
- **`data/auth/` 是账号数据**（账号表 + 各用户云同步文档 + 令牌密钥，均 gitignore）：迁移 / 备份服务器时
  必须带上这个目录；误删 = 所有用户账号与云同步数据丢失（站点本身仍能跑，会从空账号表开始）。
- 内存占用：单进程 ~100MB 内；本机同时还跑宝塔/1Panel/云监控等，内存紧张属正常，
  serve 进程带 OOM 防护，被杀会自动拉起。
- 服务重启会中断几秒，且重启后第一轮抓取需要一点时间重新预热曲线。
