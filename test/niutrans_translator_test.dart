import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/default_translator.dart';
import 'package:uyghur_interpreter/niutrans_translator.dart';
import 'package:uyghur_interpreter/translation_config.dart';
import 'package:uyghur_interpreter/translation_http.dart';

class _FakeGateway extends TranslationGateway {
  _FakeGateway(this.responses, {this.networkError = false});

  final List<String> responses;
  final bool networkError;
  int calls = 0;
  final List<Uri> uris = <Uri>[];
  final List<Map<String, String>> sentHeaders = <Map<String, String>>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  @override
  Future<String> post({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
  }) async {
    final int index = calls;
    calls += 1;
    uris.add(uri);
    sentHeaders.add(headers);
    bodies.add(jsonDecode(body) as Map<String, dynamic>);
    if (networkError) {
      throw StateError('模拟网络异常');
    }
    if (index >= responses.length) {
      throw const TranslationException('没有更多预设响应');
    }
    return responses[index];
  }
}

TranslationConfig _config({
  String appId = 'unit-test-appid',
  String key = 'unit-test-key',
  String ugCode = 'uy',
}) =>
    TranslationConfig(
      provider: TranslationProvider.niuTrans,
      appId: appId,
      key: key,
      ugCode: ugCode,
    );

NiuTransTranslator _translator(
  _FakeGateway gateway, {
  TranslationConfig? config,
}) =>
    NiuTransTranslator(
      config: config ?? _config(),
      gateway: gateway,
    );

String _ok(String text) => jsonEncode(<String, Object>{
      'from': 'zh',
      'to': 'uy',
      'tgtText': text,
    });

void main() {
  final Map<String, String> officialParams = <String, String>{
    'from': 'zh',
    'to': 'en',
    'srcText': '欢迎使用我们的翻译系统。',
    'appId': 'YcW1740708102939',
    'timestamp': '1689564909',
  };
  const String officialKey = 'a3a5c0e35bd5382fd85e9efb30c6d218';

  test('签名串按参数名 ASCII 升序拼接，空值字段不参与', () {
    final String paramStr = buildNiuTransParamStr(
      <String, String>{...officialParams, 'empty': ''},
      officialKey,
    );
    expect(
      paramStr,
      'apikey=a3a5c0e35bd5382fd85e9efb30c6d218'
      '&appId=YcW1740708102939&from=zh'
      '&srcText=欢迎使用我们的翻译系统。'
      '&timestamp=1689564909&to=en',
    );
  });

  test('authStr 是签名串的 UTF-8 MD5（官方示例值疑似笔误）', () {
    // 官方文档给的 a3935b32... 与它自己列出的 paramStr 的 MD5 不一致，
    // 这里用标准 MD5 结果锁定 Dart 实现，真实规则由 CI live check 校验。
    expect(
      buildNiuTransSignature(officialParams, officialKey),
      '3b116d5dc2eb50b0de4ff043b4bddd1d',
    );
  });

  test('默认首选 CI 实测组合：uy + 毫秒时间戳', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[_ok('ياخشىمۇسىز')]);
    final Translation result = await _translator(gateway).translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.text, 'ياخشىمۇسىز');
    expect(result.found, isTrue);
    expect(gateway.calls, 1);
    expect(gateway.bodies.single['to'], 'uy');
    expect((gateway.bodies.single['timestamp'] as String).length, 13);
  });

  test('成功解析 tgtText，标记为真实译文', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[
      _ok('ئەسسالامۇ ئەلەيكۇم'),
    ]);
    final Translation result = await _translator(gateway).translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(result.isDemo, isFalse);
    expect(result.provider, '小牛翻译');
    expect(result.text, 'ئەسسالامۇ ئەلەيكۇم');
    expect(gateway.calls, 1);
  });

  test('请求 URL、请求头与请求体字段正确，apikey 不出现在请求体', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[_ok('رەھمەت')]);
    await _translator(gateway).translate(
      '谢谢',
      Language.chinese,
      Language.uyghur,
    );
    expect(
      gateway.uris.single.toString(),
      'https://api.niutrans.com/v2/text/translate',
    );
    expect(
      gateway.sentHeaders.single['Content-Type'],
      contains('application/json'),
    );
    final Map<String, dynamic> body = gateway.bodies.single;
    expect(body['from'], 'zh');
    expect(body['to'], 'uy');
    expect(body['appId'], 'unit-test-appid');
    expect(body['srcText'], '谢谢');
    expect((body['timestamp'] as String).length, greaterThan(9));
    expect(body['authStr'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(body.containsKey('apikey'), isFalse);
  });

  test('反向翻译使用 uy → zh', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[_ok('你好')]);
    await _translator(gateway).translate(
      'ئەسسالامۇ ئەلەيكۇم',
      Language.uyghur,
      Language.chinese,
    );
    expect(gateway.bodies.single['from'], 'uy');
    expect(gateway.bodies.single['to'], 'zh');
  });

  test('维语代码仍可配置为 ug', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[_ok('رەھمەت')]);
    await _translator(gateway, config: _config(ugCode: 'ug')).translate(
      '谢谢',
      Language.chinese,
      Language.uyghur,
    );
    expect(gateway.bodies.single['to'], 'ug');
  });

  test('返回业务错误码时换备选组合再试一次', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[
      '{"errorCode":"10001","errorMsg":"请求频繁"}',
      _ok('رەھمەت'),
    ]);
    final Translation result = await _translator(gateway).translate(
      '谢谢',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(gateway.calls, 2);
    expect(gateway.bodies.first['to'], 'uy');
    expect(gateway.bodies.last['to'], 'ug');
    expect((gateway.bodies.last['timestamp'] as String).length, 13);
  });

  test('网络异常不重试，由降级链回落到演示词库', () async {
    final _FakeGateway gateway = _FakeGateway(
      <String>[_ok(' unused ')],
      networkError: true,
    );
    final Translator chain = FallbackTranslator(<Translator>[
      _translator(gateway),
      const DemoTranslator(),
    ]);
    final Translation result = await chain.translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(result.provider, '演示词库');
    expect(gateway.calls, 1);
  });

  test('缺少 APPID 或 API-KEY 时不发起网络请求', () async {
    for (final TranslationConfig config in <TranslationConfig>[
      _config(appId: ''),
      _config(key: ''),
    ]) {
      final _FakeGateway gateway = _FakeGateway(<String>[_ok('رەھمەت')]);
      final Translation result = await _translator(gateway, config: config)
          .translate('你好', Language.chinese, Language.uyghur);
      expect(result.found, isFalse);
      expect(gateway.calls, 0);
    }
  });

  test('空文本不发起请求', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[_ok('رەھمەت')]);
    final Translation result = await _translator(gateway).translate(
      '   ',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isFalse);
    expect(gateway.calls, 0);
  });

  test('空译文会换备选组合再试，不伪造结果', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[
      _ok('   '),
      _ok('رەھمەت'),
    ]);
    final Translation result = await _translator(gateway).translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(result.text, 'رەھمەت');
    expect(gateway.calls, 2);
    expect(gateway.bodies.first['to'], 'uy');
    expect(gateway.bodies.last['to'], 'ug');
  });

  test('所有组合均无译文时抛异常，由降级链兜底', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[
      _ok('   '),
      _ok('   '),
      _ok('   '),
    ]);
    final Translator chain = FallbackTranslator(<Translator>[
      _translator(gateway),
      const DemoTranslator(),
    ]);
    final Translation result = await chain.translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(gateway.calls, 3);
    expect(result.provider, '演示词库');
  });

  test('返回结构异常时抛出 TranslationException', () async {
    final _FakeGateway gateway = _FakeGateway(<String>[
      '[1, 2]',
      '[1, 2]',
      '[1, 2]',
    ]);
    await expectLater(
      _translator(gateway).translate(
        '你好',
        Language.chinese,
        Language.uyghur,
      ),
      throwsA(isA<TranslationException>()),
    );
    expect(gateway.calls, 3);
  });

  test('切换服务商会同步改变可用状态与默认终结点', () {
    final TranslationConfig config = _config();
    expect(config.provider, TranslationProvider.niuTrans);
    expect(config.hasCloudConfig, isTrue);
    expect(config.effectiveEndpoint, 'https://api.niutrans.com');

    config.provider = TranslationProvider.azure;
    expect(config.hasCloudConfig, isTrue);
    expect(
      config.effectiveEndpoint,
      'https://api.cognitive.microsofttranslator.com',
    );

    config.provider = TranslationProvider.demo;
    expect(config.hasCloudConfig, isFalse);

    config.endpoint = 'http://192.168.1.10:8080/';
    expect(config.effectiveEndpoint, 'http://192.168.1.10:8080');
  });

  test('ConfigurableTranslator 按当前配置取链，不需要重建页面', () async {
    final TranslationConfig config = TranslationConfig(
      provider: TranslationProvider.demo,
    );
    final Translator chain = ConfigurableTranslator(config);
    final Translation result = await chain.translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.provider, '演示词库');
    expect(result.text, 'ئەسسالامۇ ئەلەيكۇم');
  });
}
