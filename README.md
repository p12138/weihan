# 维汉互译 App · 自用双端工程

> **定位**：个人与朋友自用、不上架、零密钥起跑。
> 早期那份 65 文件 / 44 个 Dart / 约 6179 行 / 85 个测试的源码包
> (`uyghur-chinese-translator-source.zip`) 经三轮核验**确实不在资料库、也不在本机**，
> 因此本仓库从「先把构建工具链验证掉」的地基起步，现已长成可编译、可出包、可自动回归的工程。

> **2026-11-09 更新**：工具链与双端出包链路已全部验证通过（Android 真机试装、iOS 未签名 IPA 重签装机均正常）。
> `lib/` 已加入**第一阶段业务骨架**：对话 UI + 可插拔 `Translator` / `SpeechPort` 接口 + 离线演示词库。
> Android 真机已确认输入中文能出维文——**但那是演示词库里预置的 12 句寒暄语，不是任意句子的机器翻译**；
> 语音识别 / 合成尚未接入，按钮明确禁用，不假装可用。
> 云端翻译链（Azure → NiuTrans → Hunyuan）与讯飞维语语音属于下一阶段，接口已预留、实现待接；
> 接入时只需新增 `Translator` 实现并替换 `defaultTranslator`，界面与状态层无需改动。

---

## 0. 一句话说明现在的状态

这个目录**已经是一个完整、自包含、可以直接 push 的 Flutter 工程**：

- `flutter pub get` / `flutter analyze` / `flutter test` / `flutter build apk --debug` 全有可跑的对象
- 四个 GitHub Actions 工作流都在，引用的脚本**全部在仓库里**（不依赖拿不到的源码包）
- 不带任何密钥、证书、Token 明文
- push 后 `verify-first-build.yml` 跑质量门禁，`auto-device-smoke.yml` 跑双端模拟器装包冒烟，全部自动

> 就算 A 的源码一直找不回来，这套工程也能独立编译、出包、回归验证；
> 等源码到手，只要用它的 `pubspec.yaml` / `lib/` / `test/` 覆盖本目录同名部分，其余全部沿用。

---

## 1. 目录

| 路径 | 作用 |
|---|---|
| `pubspec.yaml` | 最小依赖；Dart 包名 `uyghur_interpreter`（合法标识符，中文名会让 `pub get` 直接失败） |
| `lib/` | `main.dart` 应用外壳、`conversation.dart` 领域模型与端口、`conversation_page.dart` 对话 UI（维文自动 RTL、方向切换、离线演示词库） |
| `test/smoke_test.dart` | 首页渲染冒烟测试 |
| `test/conversation_test.dart` | 领域模型 / 降级链 / 演示词库的 9 个单元测试 |
| `test/conversation_page_test.dart` | 3 个 widget 交互测试，把「中文→维文」等真机验证过的行为固化成自动断言 |
| `analysis_options.yaml` / `.gitignore` | lint 规则；已排除 `*.jks` / `key.properties` / `*.p12` / `*.mobileprovision` |
| `.github/workflows/verify-first-build.yml` | **push 即跑**的零密钥门禁（自检 → analyze → test → 补壳 → debug APK） |
| `.github/workflows/auto-device-smoke.yml` | **push 即跑**的双端模拟器装包冒烟（无需本机 SDK、无需证书） |
| `.github/workflows/selfuse-android.yml` | 手动出 Android APK；有 keystore 出 release，没有就明确降级 debug |
| `.github/workflows/selfuse-ios.yml` | 手动出 iOS 包；无证书明确降级未签名 `.app` / `.ipa` |
| `scripts/device_smoke_android.sh` | adb 装包 / 启动 / 崩溃检查 / 截图 |
| `scripts/device_smoke_ios.sh` | simctl 装包 / 启动 / 崩溃检查 / 截图 |
| `scripts/verify_project.py` | 纯标准库静态自检，无需 Flutter SDK |
| `scripts/bootstrap.sh` | 幂等生成 `android/` `ios/` 原生壳，补录音权限与 iOS 用途说明 |
| `scripts/push_to_github.sh` | 推送；Token 只从环境变量读，不落盘、不留 `.git/config` |
| `scripts/make_keystore.sh` | 本机生成自用 keystore |
| `android/` `ios/` `fastlane/` | 签名片段、ExportOptions、只出不上传的 Fastfile |
| `docs/` | 分发清单、密钥管理、首次编译修复手册、推送与 CI 说明 |

---

## 2. 自动化验证：以后不用手动装包测试

**结论：SDK 由 CI 调用，你什么都不用装、不用点、不用插线。**

本机（Windows）没有 Flutter / Android SDK / adb / Xcode，也装不了 iOS 模拟器；
但 GitHub 托管 runner 自带完整工具链：`ubuntu-latest` 有 Android SDK + Emulator，`macos-15` 有 Xcode + iOS Simulator。
push 之后自动跑：

| 工作流 / job | 跑什么 | 在哪跑 | 你要做什么 |
|---|---|---|---|
| `verify-first-build` | 静态自检 / analyze / 单元 + widget 测试 / debug APK | ubuntu runner | 无 |
| `auto-device-smoke` · `android-emulator` | `flutter build apk --debug --target-platform android-x64` → `adb install` → `am start` → 8 秒存活 + `FATAL EXCEPTION` 检查 + 截图 | Android 模拟器 (API 34) | 无 |
| `auto-device-smoke` · `ios-simulator` | `flutter build ios --simulator --debug --no-codesign` → `simctl install/launch` → 崩溃报告检查 + 截图 | iOS Simulator | 无 |

- **功能回归**由 `test/conversation_page_test.dart` 断言：输入「你好」出维文、未收录句不伪造译文、方向切换与语音按钮禁用。改代码后 CI 自动跑，不用手点。
- **真机级可用性**由模拟器冒烟回答：能不能装、能不能开、会不会崩。不需要证书、不需要 Apple 账号，截图在 Artifacts 里可下载。
- **唯一仍需你本人的是 iOS 真机分发**：非越狱 iPhone 只能装 Apple 签名过的 IPA，签名需要你的 Apple 账号 / 证书 / 设备 UDID，CI 代劳不了。日常自用建议以 Android APK 为主。
- macOS runner 按 10 倍计费，设备冒烟只在代码 / 配置变更时跑（`paths` 过滤），纯文档改动不跑；也可在 Actions 页手动 `Run workflow` 触发。

> **关于「用平台 SDK 做语音」**：Android / iOS 系统原生语音识别都不支持维吾尔语
> （Apple `SFSpeechRecognizer.supportedLocales()` 不含 `ug`），讯飞官方也注明其 Android / iOS SDK
> 只支持中英文和部分方言，维语仅 WebAPI 支持。所以下一阶段真实翻译与语音要走**云 WebAPI**
> （ASR → 翻译 → TTS），`Translator` / `SpeechPort` 端口正是为此预留的，装个原生 SDK 解决不了。

---

## 3. 三步跑法

### 第 1 步 · 推送

完整命令见 [`docs/PUSH-CI.md`](docs/PUSH-CI.md)。仓库已建好，日常直接 `git push`；
Token 只从环境变量读，用完立刻在 GitHub 撤销。

### 第 2 步 · 看 Actions

`verify-first-build.yml` 自动跑：

```
verify_project.py --scope all → flutter pub get → flutter analyze → flutter test
→ bootstrap.sh（补原生壳 / 权限）→ flutter build apk --debug
```

`auto-device-smoke.yml` 同时跑双端模拟器冒烟。**两个都绿 = 逻辑与装包都正常**；
红了按 [`docs/首次编译修复手册.md`](docs/首次编译修复手册.md) 从上往下逐条修。

### 第 3 步 · 出包给朋友

按 [`docs/自用双端分发清单.md`](docs/自用双端分发清单.md) 打勾：
Android 直接发 APK 最省事；iOS 需决定是否开 Apple 账号。

---

## 4. 拿到 A 的原源码之后怎么替换

| 保留（本仓库的） | 用原工程覆盖 |
|---|---|
| `.github/workflows/`（含门禁与模拟器冒烟） | `pubspec.yaml` |
| `scripts/`（含两个设备冒烟脚本） | `lib/` |
| `android/` `ios/`（bootstrap 生成的壳 + 权限声明） | `test/` |
| `analysis_options.yaml` 可按原工程调整 | 原工程的 `README.md` / `BUILD.md` 等业务文档 |

替换后重新跑 `verify-first-build.yml`。注意：

- 原工程的 `bootstrap.sh` 会「备份还原业务源码、移除 `flutter create` 生成的模板 `test/widget_test.dart`」；本仓库的 `bootstrap.sh` 是幂等补齐版，不会覆盖已有 `lib/`，两者行为不冲突，但**别同时放两份同名脚本**。
- 若原 `pubspec.yaml` 的 `environment.sdk` 与 Flutter 3.24.0 不兼容，或插件要求更高 `minSdk` / iOS deployment target，按首次编译修复手册逐条改。
- 覆盖 `android/app/src/main/AndroidManifest.xml` / `ios/Runner/Info.plist` 时别丢掉 `RECORD_AUDIO` / `INTERNET` 与两个 iOS 用途说明。

---

## 5. 能力边界（诚实说明）

- 本机**没有 Flutter SDK / Android SDK / Xcode**，真编译、出包、模拟器测试一律交给 GitHub Actions；
  `verify-first-build` 已多次全绿，Android debug APK 与 iOS 未签名 IPA 均已产出并在真机验证，
  `auto-device-smoke` 负责后续每次改动的装包回归。本机可运行的是 `scripts/verify_project.py` 静态自检。
- **当前「能翻译中文」= 演示词库命中 12 句固定寒暄语**，任意句子会明确提示未收录，不会伪造译文。
  真实机器翻译、语音识别、语音合成都还没接。
- `bootstrap.sh` 不配 Xcode Signing，需本地用 Xcode 打开 `ios/Runner.xcworkspace` 补 Team / Bundle ID。
- iOS 硬约束没变：非越狱 iPhone 只能装 Apple 签名过的 IPA。零成本让朋友也能用，只有 PWA 一条路。
- 所有证书 / keystore / p12 / 密码只给生成与配置方法，仓库内无任何明文凭证。
- 别在 8 GB 内存、常驻约 5 GB 的 NAS 上跑 Gradle，交给 GitHub Actions。
