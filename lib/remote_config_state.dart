// 远程配置「生效层」：进程级快照 + 安全白名单合并。
//
// 这里是把一份 `RemoteConfig` 落到 `translationConfig` / `speechConfig` /
// `RemoteConfigState` 的唯一入口。纯 Dart、可注入、可单测，不碰 Flutter。
//
// 安全模型（个人自用 + LAN HTTP 场景下的务实取舍）：
//   Tier A 行为类（断句/预译/开关/文案/glossary）默认即可应用；
//   Tier B 敏感类（服务商、endpoint、vcn、密钥）默认全部跳过，必须用户在
//   设置页显式 opt-in 且 URL 通过校验才生效；
//   内置凭证包（kHasBundledCredentials）永远不被任何远程配置覆盖。
// 任何失败/空值都「沿用」，绝不写空、绝不回显、绝不落盘密钥。

import 'bundled_config.dart';
import 'interpreter_segmenter.dart';
import 'remote_config.dart';
import 'speech_config.dart';
import 'translation_config.dart';

/// 生效中的配置快照（只含 Tier A 安全字段，不持有任何敏感数据）。
///
/// 与 `translationConfig` / `speechConfig` 一样是进程级单例；`reset()` 供测试隔离。
final RemoteConfigState remoteConfigState = RemoteConfigState();

class RemoteConfigState {
  RemoteConfig _current = RemoteConfig.empty;

  /// 用户在模式条上手动切过「预译」时覆盖远程值；下次同步到新配置时清空，
  /// 让远程值重新优先。这样手动开关与远程配置不各存一份真相。
  bool? _pretranslateOverride;

  /// 只保留 Tier A 的「安全视图」。translation/asr/secrets 故意留空，
  /// 保证 state 里根本不存在密钥，也就不可能回显或落盘。
  RemoteConfig get current => _current;

  int get configVersion => _current.configVersion;

  /// 断句参数（Tier A）。会话起点用 `segmenter.build(direction)` 构造断句器。
  SegmenterParams get segmenter => _current.segmentation;

  bool get pretranslate =>
      _pretranslateOverride ??
      _current.interpreter.pretranslate ??
      _kDefaultPretranslate;

  /// 设置页 / 模式条手动切换「预译」。
  void setPretranslate(bool value) => _pretranslateOverride = value;

  int get rotateAfterMs =>
      _current.interpreter.rotateAfterMs ?? _kDefaultRotateAfterMs;

  int get forceRotateAfterMs =>
      _current.interpreter.forceRotateAfterMs ?? _kDefaultForceRotateAfterMs;

  int get maxSessionFailures =>
      _current.interpreter.maxSessionFailures ?? _kDefaultMaxSessionFailures;

  /// 取一条可热改文案；没有就沿用编译期 [fallback]。
  String text(String key, String fallback) =>
      _current.strings[key] ?? fallback;

  /// 取一个开关；没有就沿用 [fallback]（默认开，避免配置缺失就关功能）。
  bool isEnabled(String key, {bool fallback = true}) =>
      _current.features[key] ?? fallback;

  String get systemPrompt => _current.systemPrompt;

  Map<String, String> get glossary => _current.glossary;

  /// 应用一份配置的安全部分。由 [applyRemoteConfig] 调用。
  void applyFrom(RemoteConfig config) {
    _pretranslateOverride = null; // 新配置到达，远程值重新优先
    _current = RemoteConfig(
      configVersion: config.configVersion,
      publishedAt: config.publishedAt,
      segmentation: config.segmentation,
      interpreter: config.interpreter,
      features: config.features,
      systemPrompt: config.systemPrompt,
      glossary: config.glossary,
      strings: config.strings,
      // translation/asr/secrets 一律不带进 state。
    );
  }

  /// 测试用：回到「全沿用」状态。
  void reset() {
    _current = RemoteConfig.empty;
    _pretranslateOverride = null;
  }

  // 与 LiveInterpreter / SpeechSegmenter 的编译期默认保持一致。
  static const bool _kDefaultPretranslate = true;
  static const int _kDefaultRotateAfterMs = 45000;
  static const int _kDefaultForceRotateAfterMs = 54000;
  static const int _kDefaultMaxSessionFailures = 2;

  @override
  String toString() => 'RemoteConfigState(v$configVersion, 仅 Tier A)';
}

/// 应用选项。全部可注入以便单测；默认值保守（零信任）。
class RemoteConfigApplyOptions {
  const RemoteConfigApplyOptions({
    this.trustSensitive = false,
    this.trustSecrets = false,
    this.bundledCredentials = kHasBundledCredentials,
    this.allowedHosts = const <String>{},
    this.allowInsecureHttp = false,
  });

  /// 设置页「信任远程配置的服务商/端点/密钥覆盖」开关。
  final bool trustSensitive;

  /// 更严格的二级开关：是否允许下发密钥（仍需非内置凭证包）。
  final bool trustSecrets;

  /// 当前安装包是否自带编译期凭证。true 时密钥永不被覆盖。
  final bool bundledCredentials;

  /// 允许覆盖 endpoint 的 host 白名单（非空时强校验）。默认由 notifier
  /// 填「更新源地址的 host」，即 endpoint 只能指向自己的 NAS 代理。
  final Set<String> allowedHosts;

  /// 是否允许 `http` / `ws`（仅局域网）。默认只允许 `https` / `wss`。
  final bool allowInsecureHttp;
}

class RemoteConfigApplyResult {
  const RemoteConfigApplyResult({
    this.applied = const <String>[],
    this.skipped = const <String, String>{},
  });

  /// 成功应用的字段名。
  final List<String> applied;

  /// 被跳过的字段 → 原因（可读）。
  final Map<String, String> skipped;

  bool hasApplied(String field) => applied.contains(field);
  bool hasSkipped(String field) => skipped.containsKey(field);
}

/// 把一份远程配置合并进运行时状态与两个配置单例。
///
/// 返回 [RemoteConfigApplyResult] 便于断言，而不必只依赖全局状态。
/// 所有配置实例都可注入，测试里传全新 `TranslationConfig()` /
/// `SpeechConfig()` / `RemoteConfigState()` 即可完全隔离。
RemoteConfigApplyResult applyRemoteConfig(
  RemoteConfig config, {
  TranslationConfig? translation,
  SpeechConfig? speech,
  RemoteConfigState? state,
  RemoteConfigApplyOptions options = const RemoteConfigApplyOptions(),
}) {
  final TranslationConfig t = translation ?? translationConfig;
  final SpeechConfig s = speech ?? speechConfig;
  final RemoteConfigState st = state ?? remoteConfigState;
  final List<String> applied = <String>[];
  final Map<String, String> skipped = <String, String>{};

  // ---- Tier A：行为类，默认应用（写入安全视图，不碰密钥）----
  st.applyFrom(config);
  if (config.segmentation.toJson().isNotEmpty) {
    applied.add('segmentation');
  }
  if (!config.interpreter.isEmpty) {
    applied.add('interpreter');
  }
  if (config.features.isNotEmpty) {
    applied.add('features');
  }
  if (config.strings.isNotEmpty) {
    applied.add('strings');
  }
  if (config.systemPrompt.isNotEmpty) {
    applied.add('prompts.systemPrompt');
  }
  if (config.glossary.isNotEmpty) {
    applied.add('glossary');
  }

  // ---- Tier B：敏感类，默认全部跳过 ----
  void sensitive(String field, void Function() write) {
    if (!options.trustSensitive) {
      skipped[field] = '未开启「信任远程配置」';
      return;
    }
    write();
    applied.add(field);
  }

  // provider / region / ugCode：不泄露密钥，但会改变后端行为，仍归入 Tier B。
  final String? provider = config.translation.provider;
  if (provider != null) {
    sensitive('translation.provider', () {
      t.provider = _providerFromName(provider) ?? t.provider;
    });
  }
  if (config.translation.region != null) {
    sensitive('translation.region',
        () => t.region = config.translation.region!);
  }
  if (config.translation.ugCode != null) {
    sensitive('translation.ugCode',
        () => t.ugCode = config.translation.ugCode!);
  }
  final String? tEndpoint = config.translation.endpoint;
  if (tEndpoint != null) {
    if (!options.trustSensitive) {
      skipped['translation.endpoint'] = '未开启「信任远程配置」';
    } else if (!_urlAllowed(tEndpoint, options,
        schemes: const <String>['https', 'http'])) {
      skipped['translation.endpoint'] = 'URL 未通过校验（需 https 且在允许的 host）';
    } else {
      t.endpoint = _stripSlash(tEndpoint);
      applied.add('translation.endpoint');
    }
  }

  if (config.asr.ugVcn != null) {
    sensitive('asr.ugVcn', () => s.ugVcn = config.asr.ugVcn!);
  }
  if (config.asr.zhVcn != null) {
    sensitive('asr.zhVcn', () => s.zhVcn = config.asr.zhVcn!);
  }
  final String? aEndpoint = config.asr.endpoint;
  if (aEndpoint != null) {
    if (!options.trustSensitive) {
      skipped['asr.endpoint'] = '未开启「信任远程配置」';
    } else if (!_urlAllowed(aEndpoint, options,
        schemes: const <String>['wss', 'ws'])) {
      skipped['asr.endpoint'] = 'URL 未通过校验（需 wss 且在允许的 host）';
    } else {
      s.endpoint = aEndpoint;
      applied.add('asr.endpoint');
    }
  }

  // ---- secrets：最严格。内置凭证包永不覆盖；非内置也需二次 opt-in ----
  config.secrets.forEach((String key, String value) {
    if (options.bundledCredentials) {
      skipped['secrets.$key'] = '内置凭证包，禁止覆盖';
      return;
    }
    if (!options.trustSensitive || !options.trustSecrets) {
      skipped['secrets.$key'] = '未开启密钥覆盖';
      return;
    }
    if (value.isEmpty) {
      skipped['secrets.$key'] = '空值，沿用';
      return;
    }
    _writeSecret(key, value, t, s);
    applied.add('secrets.$key');
  });

  return RemoteConfigApplyResult(applied: applied, skipped: skipped);
}

void _writeSecret(
  String key,
  String value,
  TranslationConfig t,
  SpeechConfig s,
) {
  switch (key) {
    case 'translation.appId':
      t.appId = value;
      break;
    case 'translation.key':
      t.key = value;
      break;
    case 'speech.appId':
      s.appId = value;
      break;
    case 'speech.apiKey':
      s.apiKey = value;
      break;
    case 'speech.apiSecret':
      s.apiSecret = value;
      break;
  }
}

TranslationProvider? _providerFromName(String name) {
  switch (name) {
    case 'niuTrans':
      return TranslationProvider.niuTrans;
    case 'azure':
      return TranslationProvider.azure;
    case 'demo':
      return TranslationProvider.demo;
    default:
      return null;
  }
}

String _stripSlash(String url) => url.replaceAll(RegExp(r'/+$'), '');

/// URL 校验：scheme 白名单、host 非空、无 userinfo、host 在允许集合里、
/// 非 https/wss 需显式允许且为局域网地址。
bool _urlAllowed(
  String raw,
  RemoteConfigApplyOptions options, {
  required List<String> schemes,
}) {
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    return false;
  }
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return false;
  }
  final String scheme = uri.scheme.toLowerCase();
  if (!schemes.contains(scheme)) {
    return false;
  }
  final bool secure = scheme == 'https' || scheme == 'wss';
  if (!secure) {
    if (!options.allowInsecureHttp || !_isLocalHost(uri.host)) {
      return false;
    }
  }
  if (options.allowedHosts.isNotEmpty &&
      !options.allowedHosts.contains(uri.host.toLowerCase())) {
    return false;
  }
  return true;
}

bool _isLocalHost(String host) {
  final String h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local')) {
    return true;
  }
  final List<String> parts = h.split('.');
  if (parts.length != 4) {
    return false;
  }
  final int? a = int.tryParse(parts[0]);
  final int? b = int.tryParse(parts[1]);
  if (a == null || b == null) {
    return false;
  }
  if (a == 127 || a == 10 || (a == 192 && b == 168)) {
    return true;
  }
  return a == 172 && b >= 16 && b <= 31;
}
