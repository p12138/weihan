// 小牛翻译 v2 文本翻译的 Translator 端口实现。
//
// 官方文档：https://niutrans.com/documents/contents/transapi_text_v2
// 签名规则：把 apikey 与全部非空参数按参数名 ASCII 升序拼成 k=v&...，取 UTF-8 MD5。
// 注意：官方文档给出的 authStr 示例值与它自己列出的 paramStr 的 MD5 对不上
// （UTF-8 / GBK / URL-encode 变体都不匹配，应是示例密钥被替换过），
// 因此这里严格按文档明文规则实现，由 CI 的 live check 用真实密钥校验。
//
// 网络层可注入，单元测试不发真实请求；失败一律抛异常交给 FallbackTranslator。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'conversation.dart';
import 'translation_config.dart';
import 'translation_http.dart';

/// 签名字符串拼接。单独导出便于单测核对排序与空值过滤。
String buildNiuTransParamStr(Map<String, String> params, String apiKey) {
  final Map<String, String> all = <String, String>{...params};
  if (apiKey.isNotEmpty) {
    all['apikey'] = apiKey;
  }
  final List<String> keys = all.keys
      .where((String key) => all[key]!.isNotEmpty)
      .toList()
    ..sort();
  return keys.map((String key) => '$key=${all[key]}').join('&');
}

/// 生成小牛 v2 权限字符串 authStr。
String buildNiuTransSignature(Map<String, String> params, String apiKey) =>
    md5.convert(utf8.encode(buildNiuTransParamStr(params, apiKey))).toString();

/// 签名函数可注入，便于以后按真实接口微调而不动网络层。
typedef NiuTransSigner = String Function(
  Map<String, String> params,
  String apiKey,
);

/// 一次请求采用的组合：维语代码 + 时间戳单位。
class _Variant {
  const _Variant(this.ugCode, this.millis);

  final String ugCode;
  final bool millis;
}

/// 小牛翻译：zh ↔ ug/uy（维吾尔语）。
class NiuTransTranslator extends Translator {
  NiuTransTranslator({
    required this.config,
    TranslationGateway? gateway,
    this.signer = buildNiuTransSignature,
  }) : gateway = gateway ?? const DartIoTranslationGateway();

  final TranslationConfig config;
  final TranslationGateway gateway;
  final NiuTransSigner signer;

  static const String _provider = '小牛翻译';
  static const String _path = '/v2/text/translate';
  static const Map<String, String> _headers = <String, String>{
    'Content-Type': 'application/json; charset=UTF-8',
  };

  String _code(Language language, String ugCode) =>
      language == Language.chinese ? 'zh' : ugCode;

  Uri get _uri {
    final String base = config.effectiveEndpoint;
    return Uri.parse(base.endsWith(_path) ? base : '$base$_path');
  }

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    if (!config.hasCloudConfig) {
      return const Translation(
        text: '',
        provider: '云端翻译未配置',
        found: false,
      );
    }
    final String clean = text.trim();
    if (clean.isEmpty) {
      return const Translation(
        text: '',
        provider: _provider,
        found: false,
      );
    }

    final String primary =
        config.ugCode.trim().isEmpty ? 'ug' : config.ugCode.trim();
    final String alternate = primary == 'ug' ? 'uy' : 'ug';
    // 语种码 ug / uy、时间戳毫秒 / 秒在文档里存在分歧：业务错误时换备选组合
    // 再试一次；网络异常不是 TranslationException，直接抛给降级链，不拖慢超时。
    final List<_Variant> variants = <_Variant>[
      _Variant(primary, true),
      _Variant(alternate, false),
    ];
    String lastError = '';
    for (final _Variant variant in variants) {
      try {
        return _parse(await _post(clean, from, to, variant));
      } on TranslationException catch (error) {
        lastError = error.message;
      }
    }
    throw TranslationException('小牛翻译两次尝试均失败：$lastError');
  }

  Future<String> _post(
    String text,
    Language from,
    Language to,
    _Variant variant,
  ) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, String> params = <String, String>{
      'from': _code(from, variant.ugCode),
      'to': _code(to, variant.ugCode),
      'appId': config.appId.trim(),
      'srcText': text,
      'timestamp': variant.millis ? '$now' : '${now ~/ 1000}',
    };
    final Map<String, String> body = <String, String>{
      ...params,
      'authStr': signer(params, config.key.trim()),
    };
    return gateway.post(
      uri: _uri,
      headers: _headers,
      body: jsonEncode(body),
    );
  }

  Translation _parse(String payload) {
    final Object? decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw const TranslationException('小牛翻译返回不是 JSON 对象');
    }
    final Object? code = decoded['errorCode'];
    if (code != null && code.toString().trim().isNotEmpty) {
      throw TranslationException(
        '小牛翻译返回错误 $code: ${decoded['errorMsg'] ?? ''}',
      );
    }
    final String text = (decoded['tgtText'] as String? ?? '').trim();
    if (text.isEmpty) {
      return const Translation(
        text: '',
        provider: _provider,
        found: false,
        isDemo: false,
      );
    }
    return Translation(
      text: text,
      provider: _provider,
      found: true,
      isDemo: false,
    );
  }
}
