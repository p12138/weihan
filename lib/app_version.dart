/// 当前安装包版本，也是「有没有新版」的比较基准。
///
/// 为什么写常量而不是读 package_info_plus：那是一个平台插件，会把这套刻意
/// 锁死的依赖链（见 pubspec 的 dependency_overrides）重新拖进版本冲突。
/// 版本号只用于展示与比较，一个常量足够。
///
/// 与 `pubspec.yaml` 的 `version:` 必须一致：CI 的 `scripts/check_version.py`
/// 会逐字比对，写错就让门禁判红，避免「界面显示 0.4.6、实际装的是 0.5.0」。
const String kAppVersion = '0.5.0+1';
