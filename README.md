# 维汉互译 App · 自用双端工程

> **定位**：个人与朋友自用、不上架、零密钥起跑。
> 早期那份 65 文件 / 44 个 Dart / 约 6179 行 / 85 个测试的源码包
> (`uyghur-chinese-translator-source.zip`) 经三轮核验**确实不在资料库、也不在本机**，
> 因此本仓库从「先把构建工具链验证掉」的地基起步，现已长成可编译、可出包、可自动回归的工程。

> **2026-11-09 更新**：工具链与双端出包链路已全部验证通过（Android 真机试装、iOS 未签名 IPA 重签装机均正常）。
> `lib/` 已有对话 UI + 可插拔 `Translator` / `SpeechPort` 接口 + 离线演示词库，
> 并已接入 **小牛翻译文本翻译**（`zh ↔ uy`，语种码由 CI 实测确定）：不用绑卡、个人 0 元，默认不启用，
> 在 App 设置里填 APPID / API-KEY 即可翻译任意句子；云端失败自动回落到 12 句演示词库，不会卡住。
> Azure Translator 实现保留为可选后端，设置页可随时切换（普通 Azure 账户注册需绑卡）。
> 语音识别 / 合成仍未接入，按钮明确禁用。
> 接入新后端只需新增 `Translator` 实现并加进 `ConfigurableTranslator`，界面与状态层无需改动。

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
| `pubspec.yaml` | 最小依赖（含 `crypto` 用于小牛签名）；Dart 包名 `uyghur_interpreter` |
| `lib/main.dart` | 应用外壳 |
| `lib/conversation.dart` | 领域模型、`Translator` / `SpeechPort` 端口、演示词库、降级链 |
| `lib/translation_http.dart` | 共用 HTTP 网关抽象与 `TranslationException`，可注入便于单测 |
| `lib/niutrans_translator.dart` | 小牛翻译 v2 实现（参数排序 + MD5 签名、语种码 / 时间戳备选重试） |
| `lib/azure_translator.dart` | Azure Translator v3.0 实现，保留为可选后端 |
| `lib/translation_config.dart` | 运行时配置单例（服务商 / APPID / API-KEY / 区域 / 终结点），不落盘、不入库 |
| `lib/default_translator.dart` | `ConfigurableTranslator`：每次调用按当前配置重建降级链，切换后端无需重建页面 |
| `lib/conversation_page.dart` | 对话 UI（维文自动 RTL、方向切换、云端设置对话框） |
| `test/smoke_test.dart` | 首页渲染冒烟测试 |
| `test/conversation_test.dart` | 领域模型 / 降级链 / 演示词库的 9 个单元测试 |
| `test/conversation_page_test.dart` | 3 个 widget 交互测试，把「中文→维文」等真机验证过的行为固化成自动断言 |
| `test/niutrans_translator_test.dart` | 16 个单测：签名、请求体、语种码、重试、降级、配置切换，全部用假网关不发网络 |
| `test/azure_translator_test.dart` | 9 个单测：请求头、语言映射、区域、降级、异常，全部用假网关不发网络 |
| `test/settings_test.dart` | 2 个 widget 测试：填入 / 清空凭证后模式条切换 |
| `analysis_options.yaml` / `.gitignore` | lint 规则；已排除 `*.jks` / `key.properties` / `*.p12` / `*.mobileprovision` |
| `.github/workflows/verify-first-build.yml` | **push 即跑**的门禁（自检 → analyze → test → 可选小牛 / Azure 实测 → 补壳 → debug APK） |
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
| `verify-first-build` | 静态自检 / analyze / 单元 + widget 测试 / 可选小牛 · Azure 实测 / debug APK | ubuntu runner | 无 |
| `auto-device-smoke` · `android-emulator` | `flutter build apk --debug --target-platform android-x64` → `adb install` → `am start` → 8 秒存活 + `FATAL EXCEPTION` 检查 + 截图 | Android 模拟器 (API 34) | 无 |
| `auto-device-smoke` · `ios-simulator` | `flutter build ios --simulator --debug --no-codesign` → `simctl install/launch` → 崩溃报告检查 + 截图 | iOS Simulator | 无 |

- **功能回归**由 `test/conversation_page_test.dart` 断言：输入「你好」出维文、未收录句不伪造译文、方向切换与语音按钮禁用。改代码后 CI 自动跑，不用手点。
- **真机级可用性**由模拟器冒烟回答：能不能装、能不能开、会不会崩。不需要证书、不需要 Apple 账号，截图在 Artifacts 里可下载。
- **云端链路**由 `test/niutrans_translator_test.dart` / `test/azure_translator_test.dart`（假网关，纯逻辑）
  与可选的 `NiuTrans live check` / `Azure Translator live check`（真实 API，需 Secret）共同覆盖。
- **唯一仍需你本人的是 iOS 真机分发**：非越狱 iPhone 只能装 Apple 签名过的 IPA，签名需要你的 Apple 账号 / 证书 / 设备 UDID，CI 代劳不了。日常自用建议以 Android APK 为主。
- macOS runner 按 10 倍计费，设备冒烟只在代码 / 配置变更时跑（`paths` 过滤），纯文档改动不跑；也可在 Actions 页手动 `Run workflow` 触发。

> **关于「用平台 SDK 做语音」**：Android / iOS 系统原生语音识别都不支持维吾尔语
> （Apple `SFSpeechRecognizer.supportedLocales()` 不含 `ug`），讯飞官方也注明其 Android / iOS SDK
> 只支持中英文和部分方言，维语仅 WebAPI 支持。所以真实语音要走**云 WebAPI**
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
→ NiuTrans / Azure live check（配置了 Secret 才跑）→ bootstrap.sh（补原生壳 / 权限）→ flutter build apk --debug
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
- **文字翻译已可接云端**：配置小牛 APPID / API-KEY 后可翻译任意句子（不用绑卡、0 元）；
  未配置时仍只有 12 句演示词库，任意句子会明确提示未收录，不会伪造译文。
  语音识别 / 语音合成都还没接。
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

另外确认三件事：装的是最新 APK（**旧包默认 `ug`，会一直失败**）、
设置页「终结点」留空、服务商选「小牛翻译」。密钥仍只在内存，重装需重填。

### 边界与后续

- 这只解决**文字 → 文字**。Azure Speech 官方语言表未列出 `ug-CN`，
  Apple `SFSpeechRecognizer` 与讯飞平台 SDK 也不含维语；维语听写与朗读
  仍需讯飞 WebAPI，那是同传阶段的事。
- 设置页的「终结点」一栏是为**阶段 2 的 NAS 代理**预留的：把密钥挪进 NAS 环境变量、
  代理对外暴露同样的翻译接口后，这里改成 NAS 地址即可，App 不用重新出包。
  长远建议：**NAS 当入口**（密钥只有一份、换供应商不动 App），
  **小牛 / Azure 当主力后端**，本地 NLLB 之类的离线模型只在服务不可用时兜底。
- 免费额度是平台政策，长期可能调整；因为 `Translator` 是可插拔端口，
  换供应商只需新增一个实现，不动界面和出包流程。
