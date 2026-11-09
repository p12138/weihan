import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/azure_translator.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/translation_config.dart';

class _FakeGateway extends TranslationGateway {
  _FakeGateway(this.response, {this.error});

  final String response;
  final Exception? error;
  int calls = 0;
  Uri? uri;
  Map<String, String>? headers;
  String? body;

  @override
  Future<String> post({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
  }) async {
    calls += 1;
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    final Exception? failure = error;
    if (failure != null) {
      throw failure;
    }
    return response;
  }
}

String _payload(String text) => jsonEncode(<Map<String, Object>>[
      <String, Object>{
        'translations': <Map<String, Object>>[
          <String, Object>{'text': text, 'to': 'ug'},
        ],
      },
    ]);

AzureTranslator _translator(
  _FakeGateway gateway, {
  String key = 'test-key',
  String region = '',
}) =>
    AzureTranslator(
      config: TranslationConfig(key: key, region: region),
      gateway: gateway,
    );

void main() {
  test('成功解析 Azure 响应，标记为非演示译文', () async {
    final _FakeGateway gateway =
        _FakeGateway(_payload('ئەسسالامۇ ئەلەيكۇم'));
    final Translation result = await _translator(gateway).translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(result.isDemo, isFalse);
    expect(result.provider, 'Azure Translator');
    expect(result.text, 'ئەسسالامۇ ئەلەيكۇم');
    expect(gateway.calls, 1);
  });

  test('请求参数与请求头正确，全球区不带 region 头', () async {
    final _FakeGateway gateway = _FakeGateway(_payload('خەير-خوش'));
    await _translator(gateway).translate(
      '再见',
      Language.chinese,
      Language.uyghur,
    );
    expect(gateway.uri!.queryParameters['api-version'], '3.0');
    expect(gateway.uri!.queryParameters['from'], 'zh-Hans');
    expect(gateway.uri!.queryParameters['to'], 'ug');
    expect(gateway.headers!['Ocp-Apim-Subscription-Key'], 'test-key');
    expect(gateway.headers!['Content-Type'], 'application/json; charset=UTF-8');
    expect(
      gateway.headers!.containsKey('Ocp-Apim-Subscription-Region'),
      isFalse,
    );
    final List<dynamic> items = jsonDecode(gateway.body!) as List<dynamic>;
    expect(items.length, 1);
    expect((items.first as Map<String, dynamic>)['Text'], '再见');
  });

  test('反向翻译使用 ug → zh-Hans', () async {
    final _FakeGateway gateway = _FakeGateway(_payload('你好'));
    await _translator(gateway).translate(
      'ئەسسالامۇ ئەلەيكۇم',
      Language.uyghur,
      Language.chinese,
    );
    expect(gateway.uri!.queryParameters['from'], 'ug');
    expect(gateway.uri!.queryParameters['to'], 'zh-Hans');
  });

  test('配置区域时带上 Ocp-Apim-Subscription-Region 头', () async {
    final _FakeGateway gateway = _FakeGateway(_payload('رەھمەت'));
    await _translator(gateway, region: 'eastasia').translate(
      '谢谢',
      Language.chinese,
      Language.uyghur,
    );
    expect(gateway.headers!['Ocp-Apim-Subscription-Region'], 'eastasia');
  });

  test('未配置密钥时不发起网络请求，交给降级链处理', () async {
    final _FakeGateway gateway = _FakeGateway(_payload('رەھمەت'));
    final Translation result = await _translator(gateway, key: '').translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(gateway.calls, 0);
    expect(result.found, isFalse);
  });

  test('空文本不发起请求', () async {
    final _FakeGateway gateway = _FakeGateway(_payload('رەھمەت'));
    final Translation result = await _translator(gateway).translate(
      '   ',
      Language.chinese,
      Language.uyghur,
    );
    expect(gateway.calls, 0);
    expect(result.found, isFalse);
  });

  test('云端异常时降级到演示词库', () async {
    final _FakeGateway gateway = _FakeGateway(
      '',
      error: const TranslationException('offline'),
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
  });

  test('Azure 返回错误结构时抛出 TranslationException', () async {
    final _FakeGateway gateway = _FakeGateway('{"error":{"code":401}}');
    await expectLater(
      _translator(gateway).translate(
        '你好',
        Language.chinese,
        Language.uyghur,
      ),
      throwsA(isA<TranslationException>()),
    );
  });

  test('空译文返回 found=false，不伪造结果', () async {
    final _FakeGateway gateway = _FakeGateway(_payload('   '));
    final Translation result = await _translator(gateway).translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isFalse);
    expect(result.text, isEmpty);
  });
}
