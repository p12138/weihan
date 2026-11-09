// 真实 dart:io 网关的回归测试，不需要外网、不需要任何凭证。
//
// 曾出现的线上问题：HttpClientRequest.write 默认按 latin1 编码字符串，
// 请求体里一有中文就抛 "Invalid argument (string): Contains invalid characters"，
// 请求根本发不出去，App 于是回落演示词库并提示「请检查 key 和网络」。
// 注入的假网关单测覆盖不到这一层，这里用本机 HttpServer 真实收发一次。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/translation_http.dart';

void main() {
  test('DartIoTranslationGateway 以 UTF-8 发送中文请求体', () async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String receivedBody = '';
    String receivedContentType = '';
    int receivedLength = -1;
    server.listen((HttpRequest request) async {
      receivedContentType = request.headers.value('content-type') ?? '';
      receivedLength = request.contentLength;
      receivedBody = await utf8.decoder.bind(request).join();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(
        'Content-Type',
        'application/json; charset=utf-8',
      );
      request.response.add(utf8.encode('{"tgtText":"ياخشىمۇسىز"}'));
      await request.response.close();
    });

    try {
      const TranslationGateway gateway = DartIoTranslationGateway();
      final String body = jsonEncode(<String, String>{'srcText': '你好'});
      final String result = await gateway.post(
        uri: Uri.parse('http://127.0.0.1:${server.port}/translate'),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: body,
      );
      expect(result, contains('ياخشىمۇسىز'));
      expect(receivedBody, body);
      expect(receivedBody, contains('你好'));
      expect(receivedContentType, contains('application/json'));
      expect(receivedLength, utf8.encode(body).length);
    } finally {
      await server.close(force: true);
    }
  });
}
