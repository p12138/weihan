# PUSH-CI.md · 推送与首次 CI

> 对应交接文档里提到的源码包 `PUSH-CI.md`。本仓库自带一份可直接照抄的版本，
> 不依赖那份拿不到的源码包。

---

## 1. 准备（一次性，约 2 分钟）

1. 打开 GitHub → New repository
   - 名字随意，例如 `uyghur-interpreter-selfuse`
   - **Private** 即可（自用，不需要公开）
   - **不要勾选** Add a README / .gitignore / license —— 仓库必须**完全空**
2. 生成 Personal Access Token
   - 经典 PAT 勾选 `repo` 即可（细粒度 token 需给 Contents 读写）
   - 设个短有效期，**用完立刻撤销**
3. 在本仓库根目录开终端，设置两个环境变量：

```bash
export GITHUB_TOKEN='<粘贴你的PAT>'       # 形如 ghp_ 开头，仅示例，不要写进任何文件
export GITHUB_REPO=你的用户名/uyghur-interpreter-selfuse
```

> Token 只在当前终端会话里，不写进任何文件、不进提交历史、`push_to_github.sh`
> 也不会把它写进 `.git/config`（推送用的是临时带凭证 URL，且不设 upstream）。

---

## 2. 推送

```bash
cd <本仓库根目录>
bash scripts/push_to_github.sh
```

脚本会依次：`git init -b main`（若未初始化）→ `git add -A` → 提交 → push →
把 origin 设成不带凭证的干净地址。**缺任何脚本或工作流都会被这一步一起提交**。

推送完成后：

```bash
# 立刻到 GitHub → Settings → Developer settings → Personal access tokens → 撤销这个 PAT
git remote -v     # 应显示 https://github.com/用户名/仓库名.git，不含 token
```

---

## 3. 看首次 CI

打开仓库 → Actions → `verify-first-build`。它会跑：

| 步骤 | 命令 | 失败时看哪 |
|---|---|---|
| 静态自检 | `python3 scripts/verify_project.py --scope all` | 自检输出，FAIL 会直接红 |
| 依赖 | `flutter pub get` | 手册 §2.1 |
| 静态分析 | `flutter analyze` | 手册 §2.2 |
| 单元测试 | `flutter test --reporter expanded` | 手册 §2.3 |
| 原生壳 | `bash scripts/bootstrap.sh` | 手册 §2.4 / §2.5 |
| 首次编译 | `flutter build apk --debug` | 手册 §2.4 |

产物：`verify-debug-apk-<run>`（debug APK）、`pubspec-lock-<run>`（`pubspec.lock`）、
`native-shells-<run>`（`android/` + `ios/` 打包，已排除 Gradle / Xcode 构建产物、本机 SDK 路径与签名资产）。

**绿灯之后必做两件事**：

```bash
# 1) 从 Artifacts 下载 pubspec.lock 放到仓库根目录并提交，锁定插件版本
# 2) 下载 native-shells-<run> 解压到仓库根目录并提交（覆盖 android/ ios/ 占位目录）
```

否则每台机器各生成一份壳，配置容易漂移。

> 下载 Artifact 需要登录态：匿名调 `/actions/artifacts/{id}/zip` 会返回 401。
> 直接在 Actions 的 run 页面点产物下载即可，不需要额外 Token。

---

## 4. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `remote: Repository not found` / 认证失败 | Token 权限不足或已过期 | 重新生成勾选 `repo` 的 PAT，确认 `GITHUB_REPO` 没写错 |
| push 被拒 `rejected - fetch first` | 仓库不是空的（勾了 README 等） | 删掉重建一个空仓库，或先 `git pull --rebase`（会引入无关初始提交） |
| Actions 一栏是空的 | 工作流文件没被提交，或仓库默认分支不是 `main` | `git ls-files .github/workflows/` 确认三个 yml 都在；把默认分支改成 `main` |
| CI 报 `scripts/verify_project.py: No such file` | 只拷了部分文件 | 确认 `scripts/` 四个脚本都在版本控制里；`push_to_github.sh` 的 `git add -A` 会自动带上 |
| 编译挂在一堆 lint | 从没真编译过，正常 | 只修**第一条**报错，按手册从上往下逐条来 |
| macOS runner 排队久 / 收费 | iOS 工作流是手动触发 | 先只跑 Android；iOS 需要时再手动触发 |
| `flutter build apk --debug` 在下载 `gradle-7.6.3-all.zip` 处失败 | GitHub Release 下载偶发中断，**不是代码问题**（实测 run #1 全绿、run #2 仅此步红，两次工程代码完全一致） | 在 Actions 页点 **Re-run jobs**，或重推一次触发新 run；连续多次失败再考虑缓存 Gradle 发行包 |

---

## 5. 之后怎么出包

- Android：Actions → `selfuse-android-apk` → `build_type=debug`（零密钥）或 `release`（需 4 个 keystore Secrets）
- iOS：Actions → `selfuse-ios-ipa` → `mode=unsigned`（零密钥，只能自己 Xcode 装）或 `adhoc`（需证书 Secrets）
- 详细打勾清单见 `docs/自用双端分发清单.md`

> 本仓库所有工作流**都不调用** `upload_to_play_store` / `upload_to_testflight` / `deliver`，
> 不建应用记录、不传 AAB、不做内容分级——定位就是自用不上架。
