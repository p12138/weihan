// 远程配置（热配置）模型：纯 Dart、无 I/O。
//
// 这是「不重装改行为」的数据载体。放在 NAS 的 `remote-config.json` 被取回后
// 解析成不可变的 [RemoteConfig]，再由 `apply_remote_config` 里的安全白名单
// 决定哪些字段真的生效。它**不能**替换已编译进 APK 的 Dart 逻辑 —— Flutter
// release 是 AOT，JSON 改不了函数体与 widget 结构，这一点见 README 第 10 节。
//
// 解析风格对齐 `update_manifest.dart`：严格门禁 + 「宁可报错也不猜」；但字段
// 一律可选/可空，null 或空串 = 「沿用当前值」（与内置凭证「留空=沿用」同源）。
// 未知 section / 字段忽略，方便以后加新旋钮而不让旧 App 整份配置失效。

import 'dart:convert';

import 'interpreter_segmenter.dart';

/// 翻译后端相关（全部敏感，默认不覆盖，见 apply 的白名单）。
class RemoteTranslationConfig {
  const RemoteTranslationConfig({
    this.provider,
    this.endpoint,
    this.region,
    this.ugCode,
  });

  final String? provider;
  final String? endpoint;
  final String? region;
  final String? ugCode;

  bool get isEmpty =>
      provider == null && endpoint == null && region == null && ugCode == null;

  Map<String, Object?> toJson() => <String, Object?>{
        if (provider != null) 'provider': provider,
        if (endpoint != null) 'endpoint': endpoint,
        if (region != null) 'region': region,
        if (ugCode != null) 'ugCode': ugCode,
      };
}

/// 语音（讯飞）相关；`endpoint` 是 wss 地址，属敏感。
class RemoteAsrConfig {
  const RemoteAsrConfig({this.ugVcn, this.zhVcn, this.endpoint});

  final String? ugVcn;
  final String? zhVcn;
  final String? endpoint;

  bool get isEmpty => ugVcn == null && zhVcn == null && endpoint == null;

  Map<String, Object?> toJson() => <String, Object?>{
        if (ugVcn != null) 'ugVcn': ugVcn,
        if (zhVcn != null) 'zhVcn': zhVcn,
        if (endpoint != null) 'endpoint': endpoint,
      };
}

/// 同传编排相关（行为类，默认即可应用）。
class RemoteInterpreterConfig {
  const RemoteInterpreterConfig({
    this.pretranslate,
    this.rotateAfterMs,
    this.forceRotateAfterMs,
    this.maxSessionFailures,
  });

  final bool? pretranslate;
  final int? rotateAfterMs;
  final int? forceRotateAfterMs;
  final int? maxSessionFailures;

  bool get isEmpty =>
      pretranslate == null &&
      rotateAfterMs == null &&
      forceRotateAfterMs == null &&
      maxSessionFailures == null;

  Map<String, Object?> toJson() => <String, Object?>{
        if (pretranslate != null) 'pretranslate': pretranslate,
        if (rotateAfterMs != null) 'rotateAfterMs': rotateAfterMs,
        if (forceRotateAfterMs != null)
          'forceRotateAfterMs': forceRotateAfterMs,
        if (maxSessionFailures != null)
          'maxSessionFailures': maxSessionFailures,
      };
}

/// 一份远程配置。所有字段都有保守默认，[empty] 表示「什么都不改」。
class RemoteConfig {
  const RemoteConfig({
    this.configVersion = 0,
    this.publishedAt,
    this.translation = const RemoteTranslationConfig(),
    this.asr = const RemoteAsrConfig(),
    this.segmentation = const SegmenterParams(),
    this.interpreter = const RemoteInterpreterConfig(),
    this.features = const <String, bool>{},
    this.systemPrompt = '',
    this.glossary = const <String, String>{},
    this.strings = const <String, String>{},
    this.secrets = const <String, String>{},
  });

  /// App 只认这一个 schema；改格式宁可让旧 App 报错，也不要用旧规则猜新文件。
  static const int supportedSchema = 1;

  /// 合法的翻译后端名（与 `TranslationProvider` 的枚举名一致）。非法值跳过该字段。
  static const Set<String> _validProviders = <String>{
    'niuTrans',
    'azure',
    'demo',
  };

  final int configVersion;
  final DateTime? publishedAt;
  final RemoteTranslationConfig translation;
  final RemoteAsrConfig asr;
  final SegmenterParams segmentation;
  final RemoteInterpreterConfig interpreter;
  final Map<String, bool> features;
  final String systemPrompt;
  final Map<String, String> glossary;
  final Map<String, String> strings;

  /// 密钥类覆盖。只在进程内存里存在，**绝不写缓存、绝不回显**（见 [toJson]）。
  final Map<String, String> secrets;

  /// 空配置：所有旋钮都「沿用」。
  static const RemoteConfig empty = RemoteConfig();

  /// 解析并校验。`schema` 缺失/不为 1、JSON 不是对象时抛 [FormatException]，
  /// 由 `RemoteConfigService` 捕获并回退缓存；数值越界钳到边界而非丢弃整份。
  static RemoteConfig parse(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('远程配置不是 JSON 对象');
    }

    final int? schema = _asInt(decoded['schema']);
    if (schema == null) {
      throw const FormatException('缺少字段 schema');
    }
    if (schema != supportedSchema) {
      throw FormatException(
        '远程配置格式为 $schema，当前 App 只支持 $supportedSchema',
      );
    }

    final Map<String, dynamic> translation =
        _section(decoded['translation']);
    final Map<String, dynamic> asr = _section(decoded['asr']);
    final Map<String, dynamic> segmentation =
        _section(decoded['segmentation']);
    final Map<String, dynamic> interpreter = _section(decoded['interpreter']);
    final Map<String, dynamic> prompts = _section(decoded['prompts']);

    final String? provider =
        _validProviders.contains(_asString(translation['provider']))
            ? _asString(translation['provider'])
            : null;

    return RemoteConfig(
      configVersion: _asInt(decoded['configVersion']) ?? 0,
      publishedAt: DateTime.tryParse(_asString(decoded['publishedAt']) ?? ''),
      translation: RemoteTranslationConfig(
        provider: provider,
        endpoint: _asString(translation['endpoint']),
        region: _asString(translation['region']),
        ugCode: _asString(translation['ugCode']),
      ),
      asr: RemoteAsrConfig(
        ugVcn: _asString(asr['ugVcn']),
        zhVcn: _asString(asr['zhVcn']),
        endpoint: _asString(asr['endpoint']),
      ),
      segmentation: SegmenterParams(
        speechThreshold: _asDoubleClamped(
          segmentation['speechThreshold'],
          0.0,
          1.0,
        ),
        silenceMs:
            _asIntClamped(segmentation['silenceMs'], 100, 5000),
        maxSentenceMs:
            _asIntClamped(segmentation['maxSentenceMs'], 1000, 120000),
        maxZhChars: _asIntClamped(segmentation['maxZhChars'], 1, 1000),
        maxUgChars: _asIntClamped(segmentation['maxUgChars'], 1, 1000),
        minDraftZhChars:
            _asIntClamped(segmentation['minDraftZhChars'], 1, 1000),
        minDraftUgChars:
            _asIntClamped(segmentation['minDraftUgChars'], 1, 1000),
        draftGapMs: _asIntClamped(segmentation['draftGapMs'], 0, 60000),
        maxDraftsPerSentence:
            _asIntClamped(segmentation['maxDraftsPerSentence'], 0, 5),
      ),
      interpreter: RemoteInterpreterConfig(
        pretranslate: _asBool(interpreter['pretranslate']),
        rotateAfterMs:
            _asIntClamped(interpreter['rotateAfterMs'], 1000, 120000),
        forceRotateAfterMs:
            _asIntClamped(interpreter['forceRotateAfterMs'], 1000, 120000),
        maxSessionFailures:
            _asIntClamped(interpreter['maxSessionFailures'], 1, 10),
      ),
      features: _asBoolMap(decoded['features']),
      systemPrompt: _asString(prompts['systemPrompt']) ?? '',
      glossary: _asStringMap(decoded['glossary']),
      strings: _asStringMap(decoded['strings']),
      // 密钥类值只认白名单键，且绝不是空串。
      secrets: _asSecretMap(_section(decoded['secrets'])),
    );
  }

  /// 缓存用的规范化 JSON。**故意不含 `secrets`**：密钥只在进程内存里生效，
  /// 绝不落盘（与 `translation_config.dart` 的「不落盘」约定一致）。
  Map<String, Object?> toJson() => <String, Object?>{
        'schema': supportedSchema,
        'configVersion': configVersion,
        if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
        if (!translation.isEmpty) 'translation': translation.toJson(),
        if (!asr.isEmpty) 'asr': asr.toJson(),
        if (segmentation.toJson().isNotEmpty)
          'segmentation': segmentation.toJson(),
        if (!interpreter.isEmpty) 'interpreter': interpreter.toJson(),
        if (features.isNotEmpty) 'features': features,
        if (systemPrompt.isNotEmpty)
          'prompts': <String, Object?>{'systemPrompt': systemPrompt},
        if (glossary.isNotEmpty) 'glossary': glossary,
        if (strings.isNotEmpty) 'strings': strings,
      };

  /// 只写非密钥字段的缓存文本。
  String toCacheJson() => jsonEncode(toJson());

  @override
  String toString() => 'RemoteConfig(v$configVersion, 无密钥明细)';
}

/// 密钥白名单键。未知键直接丢掉，避免把任意字符串塞进配置单例。
const Set<String> kSecretKeys = <String>{
  'translation.appId',
  'translation.key',
  'speech.appId',
  'speech.apiKey',
  'speech.apiSecret',
};

Map<String, String> _asSecretMap(Map<String, dynamic> section) {
  final Map<String, String> out = <String, String>{};
  section.forEach((String key, Object? value) {
    // 空白串等同「沿用」：不让一串空格把已有凭证覆盖成不可用值。
    // 与 _asString 的 trim 口径一致。
    if (kSecretKeys.contains(key) &&
        value is String &&
        value.trim().isNotEmpty) {
      out[key] = value;
    }
  });
  return out;
}

Map<String, dynamic> _section(Object? value) =>
    value is Map<String, dynamic> ? value : const <String, dynamic>{};

String? _asString(Object? value) {
  if (value is String) {
    final String text = value.trim();
    return text.isEmpty ? null : text;
  }
  return null;
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

int? _asIntClamped(Object? value, int min, int max) {
  final int? n = _asInt(value);
  if (n == null) {
    return null;
  }
  return n.clamp(min, max).toInt();
}

double? _asDoubleClamped(Object? value, double min, double max) {
  double? d;
  if (value is double) {
    d = value;
  } else if (value is num) {
    d = value.toDouble();
  } else if (value is String) {
    d = double.tryParse(value.trim());
  }
  if (d == null || d.isNaN) {
    return null;
  }
  return d.clamp(min, max).toDouble();
}

bool? _asBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    final String text = value.trim().toLowerCase();
    if (text == 'true') {
      return true;
    }
    if (text == 'false') {
      return false;
    }
  }
  return null;
}

Map<String, bool> _asBoolMap(Object? value) {
  final Map<String, bool> out = <String, bool>{};
  _section(value).forEach((String key, Object? v) {
    if (v is bool) {
      out[key] = v;
    }
  });
  return out;
}

Map<String, String> _asStringMap(Object? value) {
  final Map<String, String> out = <String, String>{};
  _section(value).forEach((String key, Object? v) {
    if (v is String && v.trim().isNotEmpty) {
      out[key] = v;
    }
  });
  return out;
}
