# NAS 更新分发（Lucky 反代）

App 的「软件更新」只做一个 HTTP GET：`<更新源地址>/latest-android.json`
（iOS 是 `latest-ios.json`），拿到清单后比对版本，再从同目录下载安装包。

这样设计的原因：

- 域名、端口随时能换，不用重新出包（清单里只写文件名）；
- 走你自己的 NAS，不依赖 GitHub 的连通性；
- 文件在你手里，草稿 Release 那套「登录才能下」的限制不影响更新。

## 1. 目录

```
deploy/nas/
├── docker-compose.yml   # nginx 静态服务，只读挂载 data/
├── nginx.conf           # 清单 no-store、安装包可续传
├── README.md
└── data/                # 实际分发的文件（建好后再放）
    ├── latest-android.json
    ├── latest-ios.json
    ├── weihan-selfuse-arm64.apk
    └── weihan-selfuse-ios-unsigned.ipa
```

## 2. 起服务

```bash
cd /volume1/docker/weihan-update   # 换成你 NAS 上的实际路径
# 把本目录的 docker-compose.yml、nginx.conf 放进来
mkdir -p data
docker compose up -d
curl -s http://127.0.0.1:8088/healthz   # 应输出 ok
```

端口 8088 只在 NAS 内网监听，公网入口交给 Lucky。

## 3. Lucky 反代

Lucky → **Web服务** → 添加 Web服务规则：

1. **监听端口**：443（或你已有的 HTTPS 端口）；
2. **TLS**：开启，证书用 Lucky 的 ACME 自动申请/续期（域名需解析到你的公网 IP）；
3. **前端域名**：如 `weihan.example.com`；
4. **子规则 → 反向代理**：
   - 前端路径：`/weihan`（或 `/`，看你是否要和其他服务共用域名）
   - 后端地址：`http://127.0.0.1:8088`
   - 保留路径前缀：如果前端用 `/weihan`，后端也带 `/weihan` 时需要在 nginx 里把
     `root` 指到包含该子目录的位置，或者直接用独立子域名（推荐，配置最简单）。

**推荐用独立子域名**（`weihan.example.com` → `http://127.0.0.1:8088`），
这样 nginx 里不需要处理路径前缀，清单与安装包都在根路径。

验证：

```bash
curl -s https://weihan.example.com/healthz
curl -s https://weihan.example.com/latest-android.json
```

第二条在还没放清单时返回 404 是正常的。

## 4. 填进 App

设置页 →「软件更新」→ 更新源地址填：

```
https://weihan.example.com
```

留空则用构建期内置的地址（`--dart-define=UPDATE_BASE=...`）。

点「检查更新」应立即返回「已是最新」或「发现新版本」。

## 5. 文件怎么来

### 手动（最省事，偶尔发版够用）

```bash
scp weihan-selfuse-arm64.apk latest-android.json \
  nas:/volume1/docker/weihan-update/data/
```

清单可以用仓库里的脚本生成：

```bash
python3 scripts/make_update_manifest.py \
  --platform android \
  --file weihan-selfuse-arm64.apk \
  --name weihan-selfuse-arm64.apk \
  --notes "本次更新内容" \
  --out latest-android.json
```

### CI 自动推送（配了 Secrets 后全自动）

在仓库 Settings → Secrets and variables → Actions 添加：

| Secret | 说明 |
|---|---|
| `NAS_HOST` | NAS 的公网地址或内网地址（GitHub Runner 要能连到） |
| `NAS_PORT` | SSH 端口，默认 22 |
| `NAS_USER` | SSH 用户名 |
| `NAS_SSH_KEY` | 对应公钥的私钥全文（建议单独生成一把，只允许写这个目录） |
| `NAS_UPDATE_DIR` | 目标目录，例如 `/volume1/docker/weihan-update/data` |

五个都配齐后，`selfuse-bundled-build` 每次出包会自动把 APK/IPA 与清单推上去；
缺任何一个就跳过推送，不影响出包本身。

> NAS 的 SSH 默认只在内网。要在公网推送，需要用 Lucky 的 **TCP 转发**
> 把某个公网端口转到 NAS 的 22（或改用 Tailscale）。只做手动上传则不需要。

## 6. 排查

| 现象 | 检查 |
|---|---|
| App 显示「连不上更新服务器」 | `curl https://域名/healthz` 是否 200；Lucky 规则是否启用 |
| 一直提示没有新版 | `curl https://域名/latest-android.json` 里的 `version` 是否大于 App 版本 |
| 下载到一半失败 | 看 `nginx.conf` 是否带了 `Accept-Ranges`；NAS 磁盘是否满 |
| 校验失败 | 清单里的 `sha256` 与文件不匹配，重新生成清单 |
