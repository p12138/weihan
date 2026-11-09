// Azure Translator 文本翻译 v3.0 的 Translator 端口实现。
//
// 网络层可注入，单元测试不发真实请求；真实连通性由 CI 的 curl 步骤验证。
// 失败一律抛异常，交给 FallbackTranslator 回落到演示词库。

import 'dart:convert';
import 'dart:io';

import 'conversation.dart';
import 'translation_config.dart';

/// 翻译服务异常。
class TranslationException implements Exception {
  const TranslationException(this.message);

  final String message;

  @override
  String toString() => 'TranslationException: $message';
}

/// 最小 HTTP 抽象，便于单测替换。
abstract class TranslationGateway {
  const TranslationGateway();

  Future<String> post({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
  });
}

/// dart:io 实现，10 秒连接超时避免无网络时长时间挂起。
class DartIoTranslationGateway extends TranslationGateway {
  const DartIoTranslationGateway();

  @override
  Future<String> post({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
  }) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final HttpClientRequest request = await client.postUrl(uri);
      for (final MapEntry<String, String> entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.write(body);
      final HttpClientResponse response = await request.close();
      final String payload = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TranslationException('HTTP ${response.statusCode}: $payload');
      }
      return payload;
    } finally {
      client.close();
    }
  }
}

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

    final Uri uri = Uri.parse('${config.endpoint}/translate').replace(
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
