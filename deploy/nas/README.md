# NAS 更新分发（Lucky 反代）

同一个「更新源地址」目录下放两类文件，App 分别取用：

| 文件 | 用途 | 触发方式 | 是否要重装 |
|---|---|---|---|
| `latest-android.json` / `latest-ios.json` + 安装包 | **整包更新**：比对版本、下载完整 APK/IPA | 「检查更新（整包 APK 重装）」 | 是 |
| `remote-config.json` | **热配置**：断句/预译/开关/文案等行为参数 | 「立即同步配置」+ 冷启动静默同步 | 否，免重装 |

> 热配置**只能改数据/参数，不能替换已编译进 APK 的 Dart 逻辑**（Flutter
> release 是 AOT）。改断句时长、切预译开关、换提示文案、切翻译后端这类
> 「下次同传就生效」的调整不用出包；要改函数体、widget 结构仍须整包更新。
> 细节见仓库根目录 README 第 10 节。

App 的整包更新只做一个 HTTP GET：`<更新源地址>/latest-android.json`
（iOS 是 `latest-ios.json`），拿到清单后比对版本，再从同目录下载安装包。
热配置则取同目录的 `remote-config.json`，两者共用同一套 `no-store` 缓存规则。

这样设计的原因：

- 域名、端口随时能换，不用重新出包（清单里只写文件名）；
- 改参数不必发版、不必重装，配置放在 NAS 上随时改随时生效；
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
    ├── remote-config.json   # 热配置（可选，见第 7 节）
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

点「检查更新（整包 APK 重装）」应立即返回「已是最新」或「发现新版本」。
点「立即同步配置（热配置·免重装）」会取同目录的 `remote-config.json`，
成功后状态行显示配置版本；断句/预译等参数在**下次开始同传**时生效，
无需重启、无需重装。冷启动也会一天静默同步一次（失败不打扰）。

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
| 同步热配置一直「未启用」 | 是否把 `remote-config.json` 放到与 `latest-android.json` 同目录；更新源地址是否填对 |

## 7. 热配置 `remote-config.json`

放在与 `latest-android.json` **同一个目录**（App 用同一个更新源地址推导）。
`nginx.conf` 已给它 `no-store`，改完刷新即时生效。下面是只含**安全项**的示例，
改完把 `configVersion` 加一，App 下次同步就能看到新版本号：

```json
{
  "schema": 1,
  "configVersion": 3,
  "publishedAt": "2026-11-15T10:00:00Z",

  "segmentation": {
    "silenceMs": 700,
    "maxSentenceMs": 10000,
    "maxZhChars": 60,
    "maxUgChars": 200,
    "minDraftZhChars": 6,
    "minDraftUgChars": 10,
    "draftGapMs": 1200,
    "maxDraftsPerSentence": 1,
    "speechThreshold": 0.12
  },
  "interpreter": {
    "pretranslate": true,
    "rotateAfterMs": 45000,
    "forceRotateAfterMs": 54000,
    "maxSessionFailures": 2
  },
  "features": {
    "continuousMode": true
  },
  "prompts": {
    "systemPrompt": "你是维汉同声传译，译文明快、口语化，别逐字死译"
  },
  "strings": {
    "configSyncLabel": "立即同步配置（热配置·免重装）"
  },
  "glossary": {
    "艾德莱斯": "ئەتلەس"
  }
}
```

字段全部**可选**：不写的项沿用 App 内置默认；数值超出合理范围会被钳到边界，
不会让整份配置失效。`schema` 必须为 `1`，缺失或不匹配时 App 会回退上次缓存。

**安全模型（默认零信任，个人自用 + 局域网场景的务实取舍）：**

- 上表这些「行为类」字段（断句 / 预译 / 开关 / 文案 / glossary / prompt）
  **默认即可生效**，改它们不需要在 App 里开任何开关；
- `translation` / `asr` 里的服务商、endpoint、vcn 以及 `secrets` 属于**敏感项**，
  默认**全部跳过**。要放行需在设置页打开「信任远程配置的服务商/端点/密钥覆盖」，
  且 endpoint 的 host 必须等于更新源地址的 host（只能指向自己的 NAS 代理）；
- `secrets` 最严格：即便打开信任开关也不下发（App 侧 `trustSecrets` 恒关），
  **自带凭证的自用包永不被任何远程密钥覆盖**；密钥只在进程内存里生效，
  绝不写入缓存、绝不回显、绝不落盘；
- 网络失败时自动回退上次成功缓存；缓存也坏则全字段沿用内置默认，
  出门没网、NAS 重启、JSON 写错都不会让 App 起不来。

> 想要「改 Dart 逻辑也不出包」属于代码热更（Shorebird 之类），与本节的热配置
> 是两回事：Flutter release AOT 不支持替换已编译代码，本工程当前只做热配置层。
