// Azure Translator 文本翻译 v3.0 的 Translator 端口实现。
//
// 保留为可选后端：普通 Azure 免费账户注册需绑卡做身份验证，
// 个人自用默认改走小牛翻译。失败一律抛异常，交给 FallbackTranslator。

import 'dart:convert';

import 'conversation.dart';
import 'translation_config.dart';
import 'translation_http.dart';

// 兼容既有 import：测试仍可从本文件拿到网关与异常类型。
export 'translation_http.dart';

/// Azure Translator 文本翻译：zh-Hans ↔ ug（维吾尔语 · 阿拉伯字母）。
class AzureTranslator extends Translator {
  AzureTranslator({
    required this.config,
    TranslationGateway? gateway,
  }) : gateway = gateway ?? const DartIoTranslationGateway();

  final TranslationConfig config;
  final TranslationGateway gateway;

  static const String _provider = 'Azure Translator';

  static String _code(Language language) =>
      language == Language.chinese ? 'zh-Hans' : 'ug';

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    if (!config.hasCloudKey) {
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

    final Uri uri =
        Uri.parse('${config.effectiveEndpoint}/translate').replace(
      queryParameters: <String, String>{
        'api-version': '3.0',
        'from': _code(from),
        'to': _code(to),
      },
    );
    final Map<String, String> headers = <String, String>{
      'Ocp-Apim-Subscription-Key': config.key.trim(),
      'Content-Type': 'application/json; charset=UTF-8',
    };
    final String region = config.region.trim();
    if (region.isNotEmpty) {
      headers['Ocp-Apim-Subscription-Region'] = region;
    }
    final String body = jsonEncode(<Map<String, String>>[
      <String, String>{'Text': clean},
    ]);

    final String payload = await gateway.post(
      uri: uri,
      headers: headers,
      body: body,
    );
    return _parse(payload);
  }

  Translation _parse(String payload) {
    final Object? decoded = jsonDecode(payload);
    if (decoded is! List<dynamic> || decoded.isEmpty) {
      throw const TranslationException('Azure 返回不是非空数组');
    }
    final Object? first = decoded.first;
    if (first is! Map<String, dynamic>) {
      throw const TranslationException('Azure 返回项格式异常');
    }
    final Object? translations = first['translations'];
    if (translations is! List<dynamic> || translations.isEmpty) {
      throw const TranslationException('Azure 未返回 translations');
    }
    final Object? entry = translations.first;
    if (entry is! Map<String, dynamic>) {
      throw const TranslationException('Azure 译文格式异常');
    }
    final String text = (entry['text'] as String? ?? '').trim();
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
