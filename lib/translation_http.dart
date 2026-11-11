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
    // 本机 / 局域网自测与未来的 NAS 代理不应被系统全局代理劫持。
    if (uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        uri.host == '::1') {
      client.findProxy = (Uri _) => 'DIRECT';
    }
    try {
      // connectionTimeout 只管「连上」；DNS 卡住、服务端收下请求却一直不回，
      // 这两个 await 会无限等。真机上表现就是「正在识别与翻译…」永远转圈。
      final HttpClientRequest request =
          await client.postUrl(uri).timeout(const Duration(seconds: 15));
      for (final MapEntry<String, String> entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      // 关键：HttpClientRequest.write 默认按 latin1 编码字符串，请求体里一旦
      // 出现中文就会抛 "Invalid argument (string): Contains invalid characters"，
      // 请求根本发不出去（CI 的 Python 版发 UTF-8 字节，所以此前没暴露）。
      // 这里显式写 UTF-8 字节并给出 Content-Length，与官方 curl 示例一致。
      final List<int> bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 15));
      final String payload = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TranslationException('HTTP ${response.statusCode}: $payload');
      }
      return payload;
    } finally {
      client.close();
    }
  }
}
