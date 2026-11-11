# 融合 · 维汉双向语音翻译（自用双端工程）

> **定位**：个人与朋友自用、不上架、零密钥起跑。
> 早期那份 65 文件 / 44 个 Dart / 约 6179 行 / 85 个测试的源码包
> (`uyghur-chinese-translator-source.zip`) 经三轮核验**确实不在资料库、也不在本机**，
> 因此本仓库从「先把构建工具链验证掉」的地基起步，现已长成可编译、可出包、可自动回归的工程。

> **2026-11-10 更新**：文字互译（小牛翻译 `zh ↔ uy`）已真机验证可用；
> **中维双向语音翻译现已接入讯飞 WebAPI**：说话 → 维语/中文识别 → 小牛翻译 → 维语/中文朗读。
> 手机号注册 + 个人实名即可，**不需要银行卡**；免费额度够个人自用。
> 未配置语音凭证时语音按钮明确禁用、朗读按钮不出现，不会假装能用；
> 云端失败自动回落文字演示词库，不卡住。配置见 [第 7 节](#7-语音翻译讯飞-webapi免绑卡个人-0-元)。
> Azure Translator 实现保留为可选文字后端（普通 Azure 账户注册需绑卡，本项目不用）。

> **2026-11-11 最新构建状态**（head `1bef3a5`，Flutter 3.24 + Gradle 8.4 / AGP 8.1.0 / Kotlin 1.9.24）：
> `verify-first-build` **#39 全绿**（含语音端到端真实链路），`auto-device-smoke` **#15 双端全绿**
> （Android Emulator 与 iOS Simulator 均完成装包 → 启动 → 崩溃检查 → 截图，无需你动手）。
> 语音版 `app-debug.apk`：189,013,837 字节，SHA-256
> `2f8eee0ff184a56d4e454217807998fada3c65c8cb8e6eb3d85bb62f8d70b83c`
> （`lib/` 与原生配置自 #32 起未变，故无需重新出包）。
> **语音三环已由 CI 全自动验证**：#39 用真实凭证让讯飞 TTS 合成 PCM 冒充录音，
> 跑通「中文→维文」和「维语→中文」两个方向的 ASR → 小牛 MT → TTS，
> 再把真实文本回灌给 widget 测试自动点语音按钮与朗读按钮。测试环节零人工。
> APK 本身仍不含任何凭证，装到手机后需在设置页填一次才会启用语音按钮（配置，非测试）。
> 这条只针对 `verify-first-build` 出的**干净包**；下面第 8 节是另一种包。

> **2026-11-11 补充（选定的第三个方向）**：新增 `selfuse-bundled-build` 工作流，
> 由 CI 在编译期注入凭证，产出**自带凭证的自用包**——装到手机开箱即用，
> 设置页一次都不用填。代价是凭证会进安装包二进制、反编译可提取，
> 因此产物按仓库可见性分流：private 走公开 Release，public 只发**草稿 Release**
> （仅你自己登录后可下载）。详见
> [第 8 节](#8-自带凭证自用包完全免手填仅自用)。

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
| `pubspec.yaml` | 依赖：`crypto`（小牛签名）、`record`（录音）、`audioplayers`（播放）；Dart 包名 `uyghur_interpreter` |
| `lib/main.dart` | 应用外壳 |
| `lib/conversation.dart` | 领域模型、`Translator` / `SpeechPort` 端口、演示词库、降级链 |
| `lib/translation_http.dart` | 共用 HTTP 网关抽象与 `TranslationException`，可注入便于单测 |
| `lib/niutrans_translator.dart` | 小牛翻译 v2 实现（参数排序 + MD5 签名、语种码 / 时间戳备选重试） |
| `lib/azure_translator.dart` | Azure Translator v3.0 实现，保留为可选后端 |
| `lib/translation_config.dart` | 文字翻译配置单例（服务商 / APPID / API-KEY / 区域 / 终结点），不落盘、不入库 |
| `lib/default_translator.dart` | `ConfigurableTranslator`：每次调用按当前配置重建降级链 |
| `lib/speech_config.dart` | 讯飞语音凭证、维语/中文发音人 vcn、代理地址（内存，不落盘） |
| `lib/xfyun_speech.dart` | HMAC-SHA256 签名 + wss 多语种 ASR / TTS 协议实现，传输层可注入；ASR 按 40ms/帧实时率发帧 |
| `lib/default_speech.dart` | `ConfigurableSpeechPort`：设置页保存凭证后立即生效，无需重新出包 |
| `lib/device_audio.dart` | 录音（16k/16bit/单声道 PCM 流）、从 PCM 直接算实时音量、录音诊断、播放（mp3，含音频会话配置）、启动期预申请麦克风权限 |
| `lib/speech_pipeline.dart` | 三环编排：ASR → MT → TTS；合成失败降级为 `speakError`，不丢文字 |
| `lib/conversation_page.dart` | 对话 UI（维文 RTL、方向切换、语音按钮、译文朗读、云端设置） |
| `lib/theme.dart` | 四套主题配色 `BrandPalette` + 全局色板 `AppColors` + 组件默认样式、维文行距 |
| `lib/palette_controller.dart` | 主题切换的唯一入口（改色板 → 通知 → 重建） |
| `lib/palette_store.dart` | 主题选择的落盘（纯文本，不引入 shared_preferences） |
| `lib/brand_mark.dart` | 应用内品牌标识，与桌面图标同源的交织双环 + 中心星芒（CustomPainter） |
| `brand/` | 设计母版：`app-icon-1024.png`、`app-icon.svg`、`splash-1080x1920.png`（只作母版，不打包） |
| `scripts/generate_brand_assets.py` | 纯标准库 PNG 读写 + Lanczos3，从母版生成双端 39 个图标 / 启动图资源；`--check` 供 CI 校验 |
| `test/ui_brand_test.dart` | 视觉回归：标语、品牌标识、方向胶囊、按住说话的语音按钮 |
| `test/theme_test.dart` | 主题系统回归：色板完整性、切换生效、设置页换色 |
| `test/audio_level_test.dart` | 音量与录音诊断单测：dBFS / PCM RMS 映射、静音与满幅、低电平提示 |
| `lib/bundled_config.dart` | 编译期「凭证已内置」标记（不含任何值），驱动设置页不回显密钥 |
| `scripts/write_bundle_defines.py` | 从 CI 环境变量生成 `--dart-define-from-file` JSON，只打印键名 |
| `.github/workflows/selfuse-bundled.yml` | 自带凭证自用包出包工作流（Android 自动 / iOS 手动可选） |
| `test/smoke_test.dart` | 首页渲染冒烟测试 |
| `test/conversation_test.dart` | 领域模型 / 降级链 / 演示词库单测 |
| `test/conversation_page_test.dart` | widget 交互测试，把「中文→维文」等真机验证过的行为固化成断言 |
| `test/niutrans_translator_test.dart` | 16 个单测：小牛签名、请求体、语种码、重试、降级（假网关） |
| `test/azure_translator_test.dart` | 9 个单测：Azure 请求头、语言映射、区域、降级（假网关） |
| `test/settings_test.dart` | 2 个 widget 测试：填入 / 清空凭证后模式条切换 |
| `test/translation_http_test.dart` | 本机 HttpServer 回归中文请求体（修 latin1 问题） |
| `test/xfyun_speech_test.dart` | 14 个语音协议单测：官方 HMAC 示例对齐、帧结构、解析、假 socket 闭环，不发网络 |
| `test/speech_pipeline_test.dart` | 4 个三环编排单测 |
| `test/live_niutrans_test.dart` | 真实凭证跑 App 的小牛 Dart 实现（无 Secret 自动跳过） |
| `test/live_xfyun_test.dart` | 真实凭证跑 TTS→ASR 闭环（无 Secret 自动跳过） |
| `analysis_options.yaml` / `.gitignore` | lint 规则；已排除 `*.jks` / `key.properties` / `*.p12` / `*.mobileprovision` |
| `.github/workflows/verify-first-build.yml` | **push 即跑**的门禁（自检 → analyze → test → 可选小牛 / 讯飞 / Azure 实测 → 补壳 → debug APK） |
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
| `verify-first-build` | 静态自检 / analyze / 单元 + widget 测试 / 可选小牛 · 讯飞 · 语音 E2E · Azure 实测 / debug APK | ubuntu runner | 无 |
| `auto-device-smoke` · `android-emulator` | `flutter build apk --debug --target-platform android-x64` → `adb install` → `am start` → 8 秒存活 + `FATAL EXCEPTION` 检查 + 截图 | Android 模拟器 (API 34) | 无 |
| `auto-device-smoke` · `ios-simulator` | `flutter build ios --simulator --debug --no-codesign` → `simctl install/launch` → 崩溃报告检查 + 截图 | iOS Simulator | 无 |

- **功能回归**由 `test/conversation_page_test.dart` 断言：输入「你好」出维文、未收录句不伪造译文、方向切换与语音按钮在未配置时禁用。改代码后 CI 自动跑，不用手点。
- **语音协议**由 `test/xfyun_speech_test.dart`（官方 HMAC 示例对齐、帧结构、响应解析、假 socket 闭环）与
  `test/speech_pipeline_test.dart`（三环顺序与失败分支）覆盖，全部不发真实网络。
- **真机级可用性**由模拟器冒烟回答：能不能装、能不能开、会不会崩。不需要证书、不需要 Apple 账号，截图在 Artifacts 里可下载。
- **云端链路**由 `NiuTrans live check`（Python）、`Dart live check`（App 的 Dart 实现）、
  `Xfyun speech live check`（TTS→ASR 闭环）、`Speech E2E live check`、`Azure Translator live check` 共同覆盖，
  都只在对应 Secret 非空时运行。`Unit tests` 会**排除** `test/live_*.dart`：
  真实云端偶发慢响应会撞上 `flutter test` 默认 30 秒超时（run #37 就因此误判红），
  且重复跑会白耗免费额度；这些链路只由专门步骤跑，各自放宽到 90 / 120 / 180 秒。
- **语音全链路零人工回归**拆成两个文件、两层验证：
  ① `test/live_speech_pipeline_test.dart`：配齐 Secret 且 `E2E_LIVE=1` 时，用真实凭证让讯飞 TTS
  合成 16k PCM 冒充麦克风录音，再跑 App 真实端口的 ASR → 小牛 MT → TTS（中→维、维→中双向），
  把真实识别文本 / 译文写进 `/tmp/weihan_e2e.json`；
  ② `test/speech_e2e_test.dart`：读该结果文件回放给 widget 测试，断言「点开始 → 点结束 →
  出现识别气泡 + 译文气泡 → 自动朗读 → 点朗读按钮再播一次」。第二层不发网络、不需要凭证，
  每次 push 都跑，改坏 UI 编排会立刻变红。
  **两层必须分文件**：同文件混用 `test()` 与 `testWidgets()` 会让整个文件被套上
  `TestWidgetsFlutterBinding` 的 fake async，真实 WebSocket 永远等不到完成（run #38 各卡满 3 分钟）。
- **唯一仍需你本人的是 iOS 真机分发**：非越狱 iPhone 只能装 Apple 签名过的 IPA，签名需要你的 Apple 账号 / 证书 / 设备 UDID，CI 代劳不了。日常自用建议以 Android APK 为主。
- macOS runner 按 10 倍计费，设备冒烟只在代码 / 配置变更时跑（`paths` 过滤），纯文档改动不跑；也可在 Actions 页手动 `Run workflow` 触发。

> **关于「用平台 SDK 做语音」**：Android / iOS 系统原生语音识别都不支持维吾尔语
> （Apple `SFSpeechRecognizer.supportedLocales()` 不含 `ug`），讯飞官方也注明其 Android / iOS SDK
> 只支持中英文和部分方言，维语仅 WebAPI 支持，Azure Speech 也没列 `ug-CN`。
> 所以真实语音必须走**云 WebAPI**（ASR → 翻译 → TTS），现已按 `SpeechPort` 端口接入讯飞；
> 装个原生 SDK 解决不了。

---

## 3. 三步跑法

### 第 1 步 · 推送

完整命令见 [`docs/PUSH-CI.md`](docs/PUSH-CI.md)。仓库已建好，日常直接 `git push`；
Token 只从环境变量读，用完立刻在 GitHub 撤销。

### 第 2 步 · 看 Actions

`verify-first-build.yml` 自动跑：

```
verify_project.py --scope all → flutter pub get → flutter analyze → flutter test
→ NiuTrans / Dart / Xfyun speech / Speech E2E / Azure live check（配置了 Secret 才跑）
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
- 录音插件 `record 5.2.0` 要求 Android `minSdk 23`，`android/app/build.gradle` 已显式设置，别改回去。
- **Android 工具链版本别回退**：`record_android 1.3.0` 自身以 AGP 8.5.2 / Kotlin 1.8.21 / Java 17 编译，Flutter 3.24 官方模板默认的 AGP 7.3.0 + Kotlin 1.7.10 会同时报
  `Module was compiled with an incompatible version of Kotlin`（旧编译器读不懂 kotlin-stdlib 1.9.x 元数据）和
  `D8: Sealed classes are not supported as program classes`（旧 R8 不认 Java 17 sealed 类）。
  本仓库把 `android/settings.gradle` 抬到 **AGP 8.1.0 + Kotlin 1.9.24**，Gradle 抬到 **8.4**，`android/app/build.gradle` 统一 **Java 17**。
  注意只升到 AGP 7.4.2 仍不够：它的 R8 还是无法 dex `kotlin-stdlib 1.9.24` / `annotation-jvm 1.9.1`（`D8: com.android.tools.r8.kotlin.H`）。
- `pubspec.yaml` 的 12 条 `dependency_overrides` 把 `record` / `audioplayers` 各平台实现锁在 Flutter 3.24 同期版本（2024-11），
  `pubspec.lock` 已回填；**升级 Flutter 之前不要移除**，否则浮动约束会把平台实现解析到两年后的新版本，出现「analyze / test 全绿、双端 build 全红」。

---

## 5. 能力边界（诚实说明）

- 本机**没有 Flutter SDK / Android SDK / Xcode**，真编译、出包、模拟器测试一律交给 GitHub Actions；
  `verify-first-build` 已多次全绿，Android debug APK 与 iOS 未签名 IPA 均已产出并在真机验证，
  `auto-device-smoke` 负责后续每次改动的装包回归。本机可运行的是 `scripts/verify_project.py` 静态自检。
- **文字与语音都已可接云端**：小牛翻译负责任意句子互译（不用绑卡、0 元），
  讯飞 WebAPI 负责中维双向听写与朗读。未配置凭证时：文字只有 12 句演示词库、
  语音按钮禁用，都会明确提示，不会伪造结果。
- **语音免费包有期限**：讯飞个人 0 元包有效期 3 个月，额度用完或到期只停服，不绑卡不会扣费；
  长期方案见第 7 节末尾。维吾尔语 TTS 发音人需要在控制台单独开启，是否包含在免费包里以实测为准。
- `bootstrap.sh` 不配 Xcode Signing，需本地用 Xcode 打开 `ios/Runner.xcworkspace` 补 Team / Bundle ID。
- iOS 硬约束没变：非越狱 iPhone 只能装 Apple 签名过的 IPA。零成本让朋友也能用，只有 PWA 一条路。
- 所有证书 / keystore / p12 / 密码只给生成与配置方法，仓库内无任何明文凭证。
- 别在 8 GB 内存、常驻约 5 GB 的 NAS 上跑 Gradle，交给 GitHub Actions。

---

## 6. 云端翻译：小牛翻译（不用绑卡、个人 0 元）

**默认后端是小牛翻译，不是 Azure**。原因：普通 Azure 免费账户注册时，微软
[官方免费账户 FAQ](https://azure.microsoft.com/free/free-account-faq/) 明确要求
「电话号码 + 信用卡或借记卡（非预付）」做身份验证——卡不扣费，但没卡就开不了；
小牛只需手机验证码，个人自用更省事。Azure 实现仍完整保留，设置页可随时切回。

配置和代码已经接好，**默认不启用**：没填 APPID / API-KEY 时行为和以前一样
（12 句演示词库）；填了才走云端，云端失败会自动回落到演示词库，不会卡住。

### 为什么可以放心用

- **不用绑卡**：手机号验证码注册；官方只写「开通 API 需绑定手机号」，
  免费注册、免费开通「文本 API」，不需要银行卡。
- **0 元且不会偷偷扣费**：每日赠送 100 积分 ≈ 20 万字符（1 积分 = 2000 字符），
  完善资料再送 500 积分。没绑卡，额度用完只是停服，不存在自动转付费。
  个人聊天按每天 200 字算，一天的免费额度够用 1000 天。
- **维语是它的老本行**：东北大学 NLP 实验室团队，2014 年即上线维汉互译，
  覆盖维 / 蒙 / 藏 / 哈 / 朝 / 彝 / 壮七大少数民族语言；新开源模型 NiuTrans.LMT
  的语种表也明确含 `ug`。国内端点 `api.niutrans.com` 直连，不用代理。
- **免费层限制**：5 QPS、单次 ≤ 5000 字符，自用完全够。

### 只做三件事

1. 手机验证码注册 [niutrans.com](https://niutrans.com/) → 登录控制台 →
   左侧「API 应用」→ 找到「文本 API」点「开通」→ 复制 **APPID** 和 **API-KEY**。
2. 在 App 右上角点设置图标，服务商保持「小牛翻译」，填 APPID 和 API-KEY，
   终结点留空，点保存。模式条会从「演示词库」变成「云端翻译」。
3. 密钥只存在 App 进程内存里，**不落盘、不入库、不随包分发**；重装 App 后要重填一次。
   绝不把 API-KEY 写进代码、`pubspec.yaml`、CI 日志或任何会提交的文件。

### CI 自动验证（不用你测）

在仓库 Settings → Secrets and variables → Actions 里加两个 Secret：

| 名称 | 值 |
|---|---|
| `NIUTRANS_APP_ID` | 控制台复制的 APPID |
| `NIUTRANS_API_KEY` | 控制台复制的 API-KEY |

**两个 Secret 必须分开建**：名称框就是键名，值框里只放那一个值，
不要写成 `NIUTRANS_APP_ID: xxx` 这种文本，也不要把两个键名塞进同一个值框——
GitHub 不会解析，CI 会读不到而跳过校验。两个值都非空，live check 才会执行。

之后每次 push，`verify-first-build` 会真实调用一次 `你好 → 维语` 并断言译文非空；
没配 Secret 时该步骤自动跳过，门禁照常全绿。**Secret 变更本身不会触发运行**：
配完两个值后，到 Actions 页对 `verify-first-build` 点一次 **Run workflow**（或任意 push 一次）
即可完成首次真实校验。脚本会优先试已验证组合，必要时再探测 `uy` / `ug` 与
毫秒 / 秒，把成功组合写进 `::notice::` 批注。

**run #22 实测结论**：`to=uy` + **毫秒时间戳**可用，`你好 → ياخشىمۇسىز`；
`ug` 会返回空译文。App 默认语种码已改为 `uy`、时间戳用毫秒，其余组合只作兜底。
官方文档的签名示例值与其 `paramStr` 的 MD5 对不上（疑似示例密钥被替换过），
签名规则也由这一步真实验证定案。

**两条 live check 分工不同**：`NiuTrans live check` 用 Python 验证凭证 / 语种码 /
服务端是否可用；`Dart live check` 直接跑 `test/live_niutrans_test.dart`，用同一组
Secret 验证 **App 里那份 Dart 实现**的 URI / 签名 / 请求体 / 响应解析整条路径，
避免「CI 全绿、手机上却失败」。两者都只在 Secret 非空时运行，凭证只从环境变量读取，
不进代码、不进产物、不打印。App 侧另有单元测试覆盖签名、请求体、重试与降级，
**不发真实网络请求**。

如需切回 Azure：设置页服务商选「Azure Translator」，填 Key 1（区域按需），
并配置 Secret `AZURE_TRANSLATOR_KEY` / `AZURE_TRANSLATOR_REGION`。

### 手机端提示「云端翻译未返回译文」怎么排查

新版 App 会把**真实原因直接显示在提示条里**（不再只给一句笼统文案），
设置页顶部也会显示当前服务商 / 终结点 / 语种码 / 诊断版标识，
截图即可确认装的是不是新包、配置有没有填错。

| 提示里出现 | 含义 | 处理 |
|---|---|---|
| `网络异常` / `SocketException` | 手机到 `api.niutrans.com` 不通 | 换网络，关掉全局代理 / VPN 再试 |
| `HTTP 401/403` 或 `小牛返回错误 1000x` | 凭证不对或签名不匹配 | 确认两个值都来自**文本 API** 卡片、没填反、前后没带空格 |
| `小牛返回空译文（响应：…）` | 语种码 / 时间戳单位变了 | 把括号里的响应内容发我，改默认值即可 |
| `uy/秒`、`ug/毫秒` | 已回落到备选组合 | 同上 |

另外确认三件事：装的是最新 APK、设置页「终结点」留空、服务商选「小牛翻译」。
密钥仍只在内存，重装需重填。

**2026-11-10 已修复的历史问题**：#23 及更早的包里，`dart:io` 网关用
`HttpClientRequest.write()` 发请求，默认按 latin1 编码，请求体一含中文就抛
`Invalid argument (string): Contains invalid characters`，**请求根本没发出去**，
于是任何中文句子都回落演示词库并误报「请检查 key 和网络」。这和 APPID / API-KEY /
手机网络都无关，CI 的 Python 校验（发 UTF-8 字节）与假网关单测都没覆盖到，
直到新增 `Dart live check` 才复现。现改为显式写 UTF-8 字节并给出 `Content-Length`，
`test/translation_http_test.dart` 用本机 HttpServer 做零外网回归。
旧包默认语种码仍是 `ug`，**必须换新包**。

### 边界与后续

- 小牛这一环只解决**文字 → 文字**；语音的听写与朗读已由讯飞 WebAPI 接入，见第 7 节。
  小牛自己的「语音翻译 API」是上传音频文件→异步查询→下载译文文件的流程（≤60 秒 / 2 MB），
  不适合面对面对话，故不用作主链路。
- 设置页的「终结点」一栏是为**阶段 2 的 NAS 代理**预留的：把密钥挪进 NAS 环境变量、
  代理对外暴露同样的翻译接口后，这里改成 NAS 地址即可，App 不用重新出包。
  长远建议：**NAS 当入口**（密钥只有一份、换供应商不动 App），
  **小牛 / Azure 当主力后端**，本地 NLLB 之类的离线模型只在服务不可用时兜底。
- 免费额度是平台政策，长期可能调整；因为 `Translator` 是可插拔端口，
  换供应商只需新增一个实现，不动界面和出包流程。

---

## 7. 语音翻译：讯飞 WebAPI（免绑卡、个人 0 元）

### 为什么是讯飞

- 官方「大模型多语种语音识别」语种表**明确含维语 `ug`** 和中文 `zh`，短音频 ≤60 秒，
  `wss://iat.cn-huabei-1.xf-yun.com/v1`，16k / 16bit / 单声道 PCM。
- 官方「在线语音合成（流式版）」支持维吾尔语发音人（控制台「民族发音人」里可见，
  官网音色叫「帕蒂古里」），`wss://tts-api.xfyun.cn/v2/tts`，小语种文本必须 `tte=UTF8`。
- Azure Speech 未列 `ug-CN`，Apple `SFSpeechRecognizer` 不含 `ug`，讯飞平台 SDK 也不支持维语；
  **只有 WebAPI 这条路能同时做维语听写与朗读**。
- 手机号注册 + 个人实名，**不需要银行卡**；0 元包到期或额度用完只停服，不会扣费。

### 免费额度（以官网当前政策为准）

| 能力 | 个人免费包 | 备注 |
|---|---|---|
| 多语种语音识别 | 0.5 万次 / 3 个月 | 并发 2；中文识别另有 2 万次包，但接口不同 |
| 在线语音合成 | 1 万次 / 3 个月 | 另「创建应用后默认每日 500 次」；赠送 5 个基础发音人 |

> 维语发音人属于民族/小语种音色，**是否包含在免费包里要在控制台实测**；
> 没开通时接口报 `11200`，此时中文朗读与双向识别仍可用，维语朗读会明确提示。
> 3 个月后免费包到期，可续领活动包，或按本节末尾的 NAS 方案长期兜底。

### 你要做的四步（都不用测试）

1. 用手机号注册 [xfyun.cn](https://www.xfyun.cn/) 并完成**个人实名认证**（不需要银行卡）。
2. 控制台新建应用，分别开通「大模型多语种语音识别」与「在线语音合成（流式版）」
   两个 **0 元试用包**；在服务页复制 **APPID / APIKey / APISecret**（三者属于同一个应用）。
3. 在「在线语音合成」→ 发音人管理里开启**维吾尔语（民族语言）发音人**，
   复制它的参数值 `vcn`；中文发音人默认 `x4_xiaoyan`，一般不用改。
4. App 右上角设置 → 语音区填 APPID / APIKey / APISecret / 维语 vcn，保存。
   模式条会变成「语音已接入」，语音按钮启用；译文气泡右侧出现喇叭可重播。

**用法**：按住语音条说话、松手结束；识别原文与译文各出一条气泡，
译文自动朗读。方向切换按钮决定「中文→维语」还是「维语→中文」，两个方向都能听、都能念。

### CI 自动验证（不用你测）

在 Settings → Secrets and variables → Actions 里加：

| 类型 | 名称 | 值 |
|---|---|---|
| Secret | `XFYUN_APP_ID` | 讯飞 APPID |
| Secret | `XFYUN_API_KEY` | 讯飞 APIKey |
| Secret | `XFYUN_API_SECRET` | 讯飞 APISecret（只用于本地签名） |
| Secret | `XFYUN_UG_VCN` | 维语发音人 vcn（可选，用于验证维语合成与听写闭环） |
| Variable | `XFYUN_ZH_VCN` | 中文发音人 vcn（可选，默认 `x4_xiaoyan`） |

三个凭证非空时，`Xfyun speech live check` 会跑 `test/live_xfyun_test.dart`：
用**同一份 App Dart 代码**让 TTS 生成 16k PCM，再把这段 PCM 喂回 ASR 识别，
验证签名、语种码、帧结构与响应解析整条路径（这是上次 latin1 事故后定下的规矩：
Python/curl 校验不能替代 Dart 实现）。维语发音人未开通只输出提示、不把门禁判红，
因为那是账号授权问题，不是代码问题。**Secret 变更不触发运行**，配完点一次 Run workflow。

**2026-11-11 实测结果（`verify-first-build` #34，`workflow_dispatch` 全绿）**：凭证配齐后
`Xfyun speech live check` 由 skipped 转为 success，真实输出为「中文合成 27732 字节 →
中文识别结果=你好。」「维语合成 32000 字节 → 维语识别结果=ياخشىمۇسىز」，
`diagnostic=` 为空。也就是说维语发音人已开通、维语听写可用，之前担心的
`11200` 授权风险已排除；同轮小牛 Python / Dart 实测也照常通过。
唯一告警是 GitHub Actions 的 Node.js 20 / setup-java v4 弃用提示，与代码无关、不判红。

**从「验协议」升级到「验整条用法」**：`Speech E2E live check` 用同一组 Secret 依次跑
`test/live_speech_pipeline_test.dart` 与 `test/speech_e2e_test.dart`。CI 上没有麦克风，
就让讯飞 TTS 先合成一段 16k PCM 当作「录到的音」，再交给 App 真实的
`ConfigurableSpeechPort` + 小牛翻译链跑完 ASR → MT → TTS，把真实识别文本与译文
写进结果文件；第二条命令由 widget 测试读回这些真数据，自动点两下语音按钮、
自动点朗读按钮并断言两条气泡与两次播放。
因此「录音字节格式对不对、三环数据有没有正确流到 UI、朗读按钮是不是真能用」
都由 CI 回答，不需要人手装包点按。UI 那一层不依赖凭证，每次 push 都会跑。

**`verify-first-build` #39 的真实输出**（`Speech E2E live check` 12 秒完成）：

```text
E2E live check: 中文识别=你好。 译文=ياخشىمۇسىز. provider=小牛翻译 录音=27732字节 朗读=6696字节
E2E live check: 维语识别=ياخشىمۇسىز 译文=你好 provider=小牛翻译 录音=32000字节 朗读=5832字节
E2E UI 回归通过：录音启停 / 双气泡 / 自动朗读 / 朗读按钮
```

两个方向的小牛翻译都返回了真译文（`isDemo=false`），维语 ASR 也识别正确，
说明此前担心的「`uy → zh` 语种码不可用」并不存在。

边界说清楚：CI runner 无物理麦克风，`record` / `audioplayers` 的平台实现本身
由双端模拟器冒烟覆盖「能装能开不崩」，真实采样与外放仍需设备；
手机端填一次凭证是使用前的配置，不是测试。

### 排障

| 提示里出现 | 含义 | 处理 |
|---|---|---|
| `合成失败 11200` | 维语发音人未开通 / vcn 填错 | 控制台开通民族发音人，复制正确 vcn 重填 |
| `朗读失败 · 维语发音人 vcn 未配置` | 只填了识别凭证，没填维语发音人 | 设置页「维语发音人」填控制台里的 vcn；文字译文不受影响 |
| `朗读失败 · 合成返回空音频` | 服务端受理了但没吐音频 | 多为该发音人未购买或额度用尽，去控制台看用量 |
| `播放失败 · …` | 音频已合成，手机放不出来 | 检查是否插着耳机 / 静音模式；iOS 用 `playAndRecord` 分类（纯输出分类会反过来禁掉录音），安卓不抢音频焦点 |
| `识别失败 10160` / `10165` | 免费包没领或已过期 | 产品页领 0 元包，或看第 5 节的长期方案 |
| `HMAC signature does not match` | 签名/时钟不对 | 三个凭证必须来自同一应用；手机时间设为自动 |
| `识别超时` / `网络异常` | 手机到讯飞端点不通 | 换网络，关掉全局代理 / VPN |
| `语音失败 · 没有识别到语音` | 没录到声音 | 允许麦克风权限，靠近话筒，说话长一点 |
| `没录到声音 · 录音 0 字节` | 录音流一个字节都没送到 | 多为权限被拒 / 麦克风被别的应用占着；看紧跟着的「峰值 x%」 |
| `云端没识别出文字（已上传 x.x s 音频）` | 音频发出去了，服务端一个字没回 | 靠近话筒说完整一句，确认顶部「我在说」的语言与实际一致 |
| `语音失败 · … · 录音 2.0s / 62.5KB / 峰值 2%` | 有字节但几乎全是静音 | 麦克风被静音 / 占用 / 蓝牙路由，检查系统录音权限与外设 |
| `需要麦克风权限` | 系统授权框被拒 | 系统设置 → 应用 → 融合 → 麦克风 → 允许；权限在 App 启动首帧后就问，不要等按住时才点 |

音频链路现在分三段提示，出问题能直接定位到「识别 / 翻译 / 合成 / 播放」哪一环，
而不是笼统一句「语音失败」。录音时看音量条也能立刻确认麦克风有没有在收声。

密钥只存在进程内存，重装需重填；诊断信息会剥掉带鉴权参数的 URL，不泄露凭证。

### 长期方案

- **NAS 代理**：把 APISecret 挪到 NAS 环境变量，代理转发 wss；App 设置页「语音代理 wss 地址」
  填代理地址即可，界面与出包流程不变，也避免凭证进 APK。
- **完全零账号**：NAS 上跑 Meta MMS 的维语 ASR（`mms-1b-all`，含 `uig`）与
  TTS（`facebook/mms-tts-uig-script_arabic`，CC-BY-NC 4.0，个人非商用可用），
  或社区微调的维吾尔语 Whisper / OmniASR。代价是 1–4 GB 模型、CPU 推理数秒、手机要能连 NAS。
  `SpeechPort` 是可插拔端口，换实现不动 UI；CI 无法验证 NAS 侧，需要单独部署。

---

## 7.5 界面与品牌

应用名 **融合**，标语「让您和您的民族朋友沟通不再有障碍」。

- **配色**：四套可切换主题，见下面「主题配色系统」。默认是松石绿 `#17635C` +
  沙金 `#C89544` + 暖白 `#FBF8F3`。深色模式刻意不做 —— 自用工具多一套配色就是
  多一份维护成本。
- **图标**：深青渐变底 + 橙 / 青绿交织双环 + 中央四角星。矢量源在
  `brand/app-icon.svg`，`app-icon-1024.png` 是 1024 方形母版。
  `scripts/generate_brand_assets.py` 用纯标准库 PNG 读写 + Lanczos3 一次生成：
  Android 自适应图标（透明底前景 + 渐变背景，图形严格锁在中心 66dp 安全区）、
  legacy / round 图标、iOS 全尺寸 `AppIcon`（无 alpha，系统自己切圆角）。
  应用内 `BrandMark` 用 CustomPainter 画同一套几何，顶栏与空状态和桌面图标是
  同一个东西；颜色固定为品牌色，不随主题漂移。
- **启动页**：`brand/splash-1080x1920.png` 先裁掉成图里的「假状态栏 9:41」和
  Home 指示条（这两样由系统绘制，留着会出现两份），再按密度出图。Android 用
  深青 `windowBackground` + 居中品牌主视觉，12+ 另配
  `windowSplashScreenBackground`/`AnimatedIcon`；iOS `LaunchScreen.storyboard`
  改成四边贴边 + `scaleAspectFill`，底色 `#062538`。为控制体积，Android 启动图
  只留一份 `drawable-xxhdpi`，由系统按屏幕密度缩放。
  **没有 Flutter 层的假启动页** —— 那种要卡一个定时器，只会让冷启动更慢，
  还会把 widget 测试全打乱。
- **改设计**：换掉 `brand/` 里的母版后跑 `python3 scripts/generate_brand_assets.py`，
  再用 `--check` 校验 39 个资源齐全、尺寸正确、且没有旧密度的启动图残留；
  CI 每轮自动跑 `--check`，资源丢了会直接判红。
- **主界面**：渐变顶栏（品牌标识 + 名称 + 标语 + 调色板/设置）、**方向切换卡**
  （中文 / 维语两枚语言胶囊 + 中间交换键 + 一行通道状态）、空状态（92px 标识 +
  标语 + 三条操作提示）、双语气泡（自己的在右用渐变深底，对方在左用白卡描边）、
  底部输入区（圆角输入框 + 圆形发送键 + **按住说话**的语音条）。
- **方向切换控件**：左侧「汉」胶囊恒为主色、右侧「维」胶囊恒为强调色，当前
  「我在说」的那一侧是实心渐变 + 投影，另一侧是同色系浅底细边。点任一胶囊即可
  把它设为「我说的话」，中间圆形交换键点一下也能翻转。**颜色是语言的一部分**，
  换主题时两个色一起换，但「哪个颜色对应哪种语言」不变 —— 不看字也认得出方向。
- **按住说话**：语音按钮是「按下就开始录、松手就结束」，不是点一下开始、再点一下
  结束。`Listener` 直接收原始指针事件（`onPointerDown/Up/Cancel`），不等手势竞技场
  判胜负，所以按下那一瞬间就开始录音；手指滑出按钮再松开也能正常收尾，来电之类的
  系统打断会走 `onPointerCancel`。按下时按钮缩到 0.975 并换警示色；录到的音频为空时
  明确提示「没录到声音」，不把空音频丢给云端。
  **麦克风权限在 App 首帧之后就问下来**（`primeMicrophonePermission`）：`record` 的
  `hasPermission()` 会弹系统框并等用户点，若拖到按住那一刻才问，用户得松手去点，
  松手事件先到、权限回来那段录音又被当成「按太快」丢掉 —— 第一次按住会毫无反应。
- **录音音量可视化（微信式）**：录音时浮层从会话区底部浮出，13 根竖条的高度吃的是
  **真实录到的 PCM**（对每个音频块求 RMS → dBFS → 0..1，用 √ 压低端），旁边跟着计时。
  不再订阅 `record` 的 `onAmplitudeChanged`：那条平台振幅流在 `startStream` 模式下
  时有时无，波形不动会让人误判成「识别不到声音」；而 PCM 块就在手里，波形动不动
  直接等于录音流有没有在送数据。安静时条条贴地平躺、说话时中间几根先窜起来。
  没有音量流（测试里的假实现）时它就静止不动，不影响录音，也不会让
  `pumpAndSettle` 挂死（不用 Timer、不用 `repeat()`）。
- **录音自诊断**：松手后把「时长 / 字节数 / 峰值电平」算出来贴在失败提示里，
  例如 `语音失败 · … · 录音 2.0s / 62.5KB / 峰值 2%`。峰值低于 5% 会直接点出
  「电平极低，麦克风可能没在收声」，一眼分清是没录到、全是静音、还是云端没认出。
  `stop()` 之前先等 60ms 让平台通道的尾帧投递完（插件的 `stop()` 会立刻取消底层
  订阅，之后再等是没用的）；ASR 按官方 40ms/帧实时率上传，超时预算把上传时间算进去。
- **朗读失败不吞文字**：识别 → 翻译 → 合成里，只有前两步是「必须成功」的。
  合成抛错或被服务端判空时，原文与译文照常上屏，提示里直接写清原因
  （例如「维语发音人 vcn 未配置 · 到设置页填讯飞「发音人管理」里的维吾尔语发音人」），
  译文气泡右侧的喇叭还能手动重试。早期版本把合成异常当整轮失败，表现就是
  「说中文没声音、连字都没出来」。
- **可读性细节**：维吾尔文用 19px / 1.95 行距（阿拉伯字母连写需要更松的行距）；
  系统字号放大最多按 1.3 倍收口，避免气泡与输入区挤成一团。
- **无动画依赖**：全页没有无限循环动画（脉冲、loading 圈），`pumpAndSettle`
  才不会被挂死 —— 这是 E2E 能稳定跑的前提，改 UI 时不要引入 `repeat()`。

### 主题配色系统

`lib/theme.dart` 里每套配色是一个 `const BrandPalette` 实例，现在有四套：

| id | 名字 | 中文侧（主色） | 维文侧（强调色） |
|---|---|---|---|
| `adeles` | 艾德莱斯 | 松石绿 `#17635C` | 沙金 `#C89544` |
| `bilibili` | B 站 | 哔哩哔哩粉 `#FB7299` | 天依蓝 `#00A1D6` |
| `pomegranate` | 石榴 | 石榴红 `#A62B3C` | 麦金 `#D9A441` |
| `indigo` | 靛蓝 | 湖蓝 `#3D5AFE` | 琥珀 `#E8A33D` |

- **切换入口**：顶栏调色板按钮（按顺序切下一套）、设置页「主题配色」四个色卡。
  选中即生效，**重启后保留**（存在系统临时目录的一个纯文本文件里，见
  `lib/palette_store.dart`；不引入 shared_preferences，是为了不再动那套锁死的插件链）。
- **实现方式**：`AppColors` 是全局可变色板 + 静态 getter，切主题先改色板再
  `notifyListeners`，`BaseApp` 重建整个 `MaterialApp`。全工程 80 多处取色因此
  不需要传 `BuildContext`。
- **代价（改 UI 时务必知道）**：这些颜色不再是编译期常量，**任何
  `const Widget(... color: AppColors.x)` 都会编译不过**，必须去掉 `const`。
  新增取色点时按这个规矩写。
- 深色模式仍然不做：四套浅色已经够挑，再做一套深色就是八份要维护的对比度。

### 透明玻璃与 iOS 版本适配

`lib/glass.dart` 按系统大版本决定"玻璃有多厚"，同一套 UI 不做分支：

| 系统 | 效果 | 模糊 | 填充 |
|---|---|---|---|
| iOS 26 / 27 | 液态玻璃：大圆角 + 顶部高光 + 亮边 | 30px | 56% |
| iOS 17 / 18 | 磨砂玻璃 | 22px | 72% |
| iOS 12–16 | 实色（老系统大面积模糊会掉帧） | 0 | 94% |
| Android | 磨砂玻璃（比 iOS 略厚一点，保证可读） | 16px | 80% |

- 页面底下铺一层**静态极光底纹**（三团径向渐变，无动画），玻璃才有东西可折射；
  没有这层，`BackdropFilter` 只是在白底上糊一层，看着像脏。
- 玻璃用在：状态条、底部输入区、设置面板、（液态玻璃下）边缘高光。
- 版本号取自 `Platform.operatingSystemVersion`（形如 `Version 18.2 (Build ...)`），
  解析不出来一律退回实色 —— 宁可少特效，也不要糊成一片。
- 设置面板底部有一行「玻璃 …」，直接显示当前命中的规则，真机上一眼能确认适配对不对。
- iOS 26/27 的系统级 Liquid Glass 只作用于**原生控件**；本项目 UI 全在 Flutter 里自绘，
  所以新系统带来的外观变化只涉及启动屏与桌面图标，这两处已经按品牌重做。

## 8. 自带凭证自用包（完全免手填，仅自用）

这一节对应「连设置页那一次填写也省掉」的选择。**它改变了原先「密钥不进包」的约定**，
只适用于本人自用的包，不能分发给任何人。

### 怎么工作

`selfuse-bundled.yml` 在 runner 上把 GitHub Secrets 写进一份临时 JSON
（`scripts/write_bundle_defines.py`，0600、用完即删、只打印键名不打印值），
再用 `flutter build apk --debug --dart-define-from-file=...` 注入。
App 里 `String.fromEnvironment` 早就有对应入口，所以**源码仓库依旧没有任何凭证**：
只有键名映射、Git 历史干净、`verify_project.py` 的硬编码扫描照常 PASS。

注入后 `BUNDLED_SELFUSE=true`，设置页：

- 顶部显示「凭证已内置于安装包，无需填写；如需更换可在此覆盖」；
- 五个密钥输入框初始留空，**不把内置凭证明文显示在手机屏幕上**；
- 留空直接点保存不会把内置值清空（否则语音按钮会莫名变灰）；
- 想临时换账号，照常输入即可覆盖，仍是内存态、不落盘。

CI 会先跑 `test/bundled_config_test.dart`（带同一份 define 文件）确认注入生效、
不回显、保存不清空，再做原生构建，最后在 APK 里只搜索 `BUNDLED_SELFUSE` 这个**键名**
确认配置进了产物（不读取、不打印任何凭证值）。

### 三种包别拿混

| 产物 | 出自 | 含凭证 | 用途 |
|---|---|---|---|
| `verify-debug-apk-*` | `verify-first-build` | 否 | 干净门禁包，装了要在设置页填一次；可安全给人 |
| `weihan-selfuse-arm64.apk`（Releases，推荐） | `selfuse-bundled-build` | **是** | 本人自用，64 位手机，体积最小 |
| `weihan-selfuse-v7a.apk`（Releases） | 同上 | **是** | 32 位老机器兜底 |
| `weihan-selfuse-debug-fallback.apk`（Releases） | 同上 | **是** | 上面两个装不上/闪退时才用，体积大 |
| `weihan-selfuse-bundled-apk-*`（Artifacts，zip） | 同上 | **是** | 同一批包的 zip 备份，保留 3 天 |
| `weihan-selfuse-bundled-simulator.ipa` | 同上（手动勾选 with_ios） | **是** | iOS 模拟器自用，未签名 |

### 体积（2026-11-11 起）

早期只出 `flutter build apk --debug`，四个 ABI 各带一份 JIT 引擎，**实测 189 MB**，
传个微信都要转半天。现在改成 release + 按 ABI 分包：

| 包 | 构建方式 | 典型体积 |
|---|---|---|
| `arm64-v8a` release | `--release --split-per-abi` | ≈ 20 MB |
| `armeabi-v7a` release | 同上 | ≈ 18 MB |
| debug 兜底 | `--debug --target-platform android-arm64` | ≈ 80 MB |

降幅来自三件事：AOT 编译去掉 JIT 引擎与 kernel 快照、单 ABI 不再背四份
`libflutter.so`、release 默认开启图标字体 tree-shaking。没有开 R8/资源压缩——
那需要为每个插件写 keep 规则，省下的 MB 抵不上一次线上崩溃的排查成本。

### 触发方式与下载

- `lib/` / `pubspec` / 原生壳 / `scripts/` / 本工作流变更并 push 到 main 时**自动跑**；
  也可在 Actions 页手动 `Run workflow`。想顺带出 iOS 包，勾 `with_ios`（macOS 计费分钟按 10 倍计）。
- **直接下 `.apk`（推荐）**：仓库 **Releases** 页 → 「自用语音翻译包（最新）」→
  `weihan-selfuse-arm64.apk`，点一下就是安装包，不用解压。
  固定直链：`https://github.com/p12138/weihan/releases/download/selfuse-latest/weihan-selfuse-arm64.apk`
- **为什么 Artifacts 是 zip**：GitHub Actions 的 Artifacts 由平台强制打包成 zip，
  无法改成裸文件；想下原始 `.apk` 只能走 Releases（本工作流已自动发布）。
- 每次构建会发两个 Release：滚动 tag `selfuse-latest`（覆盖，直链固定）与
  版本 tag `v<版本>-build<run号>`（留历史，出问题可回退到某一版）。
  Release 说明里写了版本、commit、APK 的 SHA-256 与体积。
- Artifacts 里同名的 `weihan-selfuse-bundled-apk-<run号>`（zip）保留 **3 天**作为备份。
- **仓库可见性决定发布方式**（2026-11-11 起）：
  - **private**：Artifact + 公开 Release 都传，直链点开即下。
  - **public**：Artifact 与公开 Release 都能被匿名下载（artifact 还有 nightly.link 这类
    零凭证代理），所以工作流改为**只发草稿 Release**——只有拥有写权限的你登录后
    能看见和下载，匿名访客 404；同时把历史上已公开的包**自动撤回为草稿**。
    想看 CI 跑到哪一步又要安全，就用这个模式。
  - 若明确接受密钥外泄风险（不建议）：Variable `BUNDLE_ALLOW_PUBLIC=1` 可强制公开上传。

### 必须接受的风险

1. 凭证以明文形式编进 Dart snapshot / 原生二进制，**反编译可提取**；这层不是加密，也不是混淆保护。
2. 任何拿到这个 APK/IPA 的人都能用你的讯飞与小牛额度，并可造成额度盗用或欠费。
3. 建议：仓库转 private、产物只留 3 天、包只装在自己设备、不要备份到公有网盘；
   一旦发现泄露，去讯飞与小牛控制台**重置 APIKey / APISecret**，再更新同名 Secrets 重跑即可。
4. 想同时做到「完全免手填」和「凭证不进包」，只有第 7 节的 **NAS 代理**路线：
   把 APISecret 放 NAS 环境变量，App 内置代理地址（地址不是密钥），由代理签名转发。
