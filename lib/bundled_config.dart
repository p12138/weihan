// 自用包「凭证内置」标记。
//
// 只有 CI 出「自带凭证的自用包」时才通过 --dart-define-from-file 把
// BUNDLED_SELFUSE 置为 true；源码仓库里它恒为 false，不含任何凭证值。
//
// 设计原因：凭证来自编译期注入后，设置页若照旧把 speechConfig / translationConfig
// 的当前值回填进输入框，等于把内置密钥明文显示在手机屏幕上；保存时若用户没动
// 这些框又会把空字符串覆盖回去，导致语音按钮莫名变灰。因此内置模式下：
//   1. 密钥输入框初始留空（不回显）；
//   2. 留空表示「沿用内置值」，只有主动填写才覆盖；
//   3. 设置页显式提示凭证已内置。
//
// 注意：内置凭证会打进安装包二进制，反编译可提取。这个开关只改善使用体验，
// 不构成任何加密或保护，见 README「自带凭证自用包」一节。

/// 当前安装包是否自带编译期注入的凭证。
const bool kHasBundledCredentials = bool.fromEnvironment('BUNDLED_SELFUSE');

/// 设置页在内置凭证模式下显示的说明（测试也引用此常量，避免文案漂移）。
const String kBundledCredentialsNotice =
    '凭证已内置于安装包，无需填写；如需更换可在此覆盖';
