// 云端翻译共用的最小 HTTP 抽象与异常类型。
//
// 网络层可注入，单元测试不发真实请求；真实连通性由 CI 的 live check 验证。
// 从 azure_translator.dart 抽出，供 Azure / NiuTrans 等多个 Translator 实现复用。

import 'dart:convert';
import 'dart:io';

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
