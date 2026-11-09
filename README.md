# 维汉互译 App · 自用双端构建仓库（地基版）

> **定位**：个人与朋友自用、不上架、零密钥起跑。
> **这里不是业务代码** —— 资料库《维汉互译 App｜跨端交接与源码》描述的那份
> 65 文件 / 44 个 Dart / 约 6179 行 / 85 个测试的 Flutter 源码包
> (`uyghur-chinese-translator-source.zip`) 经三轮核验**确实不在资料库、也不在本机**。
> 本仓库是「源码找回之前，先把构建工具链验证掉」的可编译地基。

> **2026-11-09 更新**：工具链与双端出包链路已全部验证通过（Android 真机试装、iOS 未签名 IPA 重签装机均正常）。
> `lib/` 现已加入**第一阶段业务骨架**：对话 UI + 可插拔 `Translator` / `SpeechPort` 接口 + 离线演示词库。
> 演示词库只覆盖常见寒暄句，**不是真实机器翻译**；语音识别 / 合成尚未接入，按钮明确禁用，不假装可用。
> 云端翻译链（Azure → NiuTrans → Hunyuan）与讯飞维语语音属于下一阶段，接口已预留、实现待接；
> 接入时只需新增 `Translator` 实现并替换 `defaultTranslator`，界面与状态层无需改动。

---

## 0. 一句话说明现在的状态

这个目录**已经是一个完整、自包含、可以直接 push 的 Flutter 工程**：

- `flutter pub get` / `flutter analyze` / `flutter test` / `flutter build apk --debug` 全有可跑的对象
- 三个 GitHub Actions 工作流都在，且它们引用的脚本**全部在仓库里**（不依赖拿不到的源码包）
- 不带任何密钥、证书、Token 明文
- 一旦 push，`verify-first-build.yml` 会自动回答那个唯一没验证过的问题：**这套 Flutter 3.24.0 + Java 17 工具链到底能不能编出 debug APK**

> 换句话说：就算 A 的源码一直找不回来，你也能先把「CI 能不能跑」这件事确定下来；
> 等源码到手，只要用它的 `pubspec.yaml` / `lib/` / `test/` 覆盖本目录同名部分，其余全部沿用。

---

## 1. 目录

| 路径 | 作用 |
|---|---|
| `pubspec.yaml` | 最小依赖；Dart 包名 `uyghur_interpreter`（合法标识符，中文名会让 `pub get` 直接失败） |
| `lib/` | `main.dart` 应用外壳、`conversation.dart` 领域模型与端口、`conversation_page.dart` 对话 UI（维文自动 RTL、方向切换、离线演示词库） |
| `test/smoke_test.dart` | 1 个冒烟测试，保证 `flutter test` 有东西可跑 |
| `analysis_options.yaml` / `.gitignore` | lint 规则；已排除 `*.jks` / `key.properties` / `*.p12` / `*.mobileprovision` |
| `.github/workflows/verify-first-build.yml` | **push 即跑**的零密钥门禁（自检 → analyze → test → 补壳 → debug APK） |
| `.github/workflows/selfuse-android.yml` | 手动出 Android APK；有 keystore 出 release，没有就明确降级 debug |
| `.github/workflows/selfuse-ios.yml` | macOS runner 出 iOS 包；无证书明确降级未签名 `.app` |
| `scripts/verify_project.py` | 纯标准库静态自检，无需 Flutter SDK |
| `scripts/bootstrap.sh` | 幂等生成 `android/` `ios/` 原生壳，补录音权限与 iOS 用途说明 |
| `scripts/push_to_github.sh` | 推送；Token 只从环境变量读，不落盘、不留 `.git/config` |
| `scripts/make_keystore.sh` | 本机生成自用 keystore |
| `android/` `ios/` `fastlane/` | 签名片段、ExportOptions、只出不上传的 Fastfile |
| `docs/` | 分发清单、密钥管理、首次编译修复手册、推送与 CI 说明 |

---

## 2. 三步跑法

### 第 1 步 · 推到空仓库（唯一需要你动手的地方）

完整命令见 [`docs/PUSH-CI.md`](docs/PUSH-CI.md)，最简版：

```bash
cd <本目录>
export GITHUB_TOKEN=<勾选 repo 的 PAT>     # 用完立刻在 GitHub 撤销
export GITHUB_REPO=用户名/仓库名           # 必须是完全空的仓库
bash scripts/push_to_github.sh
```

### 第 2 步 · 看 Actions

`verify-first-build.yml` 自动跑：

```
verify_project.py --scope all → flutter pub get → flutter analyze → flutter test
→ bootstrap.sh（补原生壳 / 权限）→ flutter build apk --debug
```

产物：`verify-debug-apk-*` 与 `pubspec-lock-*`。**绿灯 = 工具链没问题**；
红了按 [`docs/首次编译修复手册.md`](docs/首次编译修复手册.md) 从上往下逐条修。

### 第 3 步 · 出包给朋友

按 [`docs/自用双端分发清单.md`](docs/自用双端分发清单.md) 打勾：
Android 直接发 APK 最省事；iOS 需决定是否开 Apple 账号。

---

## 3. 拿到 A 的原源码之后怎么替换

| 保留（本仓库的） | 用原工程覆盖 |
|---|---|
| `.github/workflows/`（3 个工作流） | `pubspec.yaml` |
| `scripts/`（4 个脚本） | `lib/`（44 个 Dart 文件） |
| `android/` `ios/`（bootstrap 生成的壳 + 权限声明） | `test/`（9 个文件 / 85 个用例） |
| `analysis_options.yaml` 可按原工程调整 | 原工程的 `README.md` / `BUILD.md` 等业务文档 |

替换后重新跑 `verify-first-build.yml`。注意：

- 原工程的 `bootstrap.sh` 会「备份还原业务源码、移除 `flutter create` 生成的模板 `test/widget_test.dart`」；本仓库的 `bootstrap.sh` 是幂等补齐版，不会覆盖已有 `lib/`，两者行为不冲突，但**别同时放两份同名脚本**。
- 若原 `pubspec.yaml` 的 `environment.sdk` 与 Flutter 3.24.0 不兼容，或插件要求更高 `minSdk` / iOS deployment target，按首次编译修复手册逐条改。
- 覆盖 `android/app/src/main/AndroidManifest.xml` / `ios/Runner/Info.plist` 时别丢掉 `RECORD_AUDIO` / `INTERNET` 与两个 iOS 用途说明。

---

## 4. 能力边界（诚实说明）

- 本机**没有 Flutter SDK / Android SDK / Xcode**，真编译与出包一律交给 GitHub Actions；
  `verify-first-build` 已多次全绿，Android debug APK 与 iOS 未签名 IPA 均已产出并在真机验证。
  业务层骨架的 `flutter analyze` / `flutter test` / `flutter build apk` 结果同样以 CI 日志为准。
  本地可运行的是 `scripts/verify_project.py` 静态自检（无需 Flutter SDK）。
- `bootstrap.sh` 不配 Xcode Signing，需本地用 Xcode 打开 `ios/Runner.xcworkspace` 补 Team / Bundle ID。
- iOS 硬约束没变：非越狱 iPhone 只能装 Apple 签名过的 IPA。零成本让朋友也能用，只有 PWA 一条路。
- 所有证书 / keystore / p12 / 密码只给生成与配置方法，仓库内无任何明文凭证。
- 别在 8 GB 内存、常驻约 5 GB 的 NAS 上跑 Gradle，交给 GitHub Actions。
