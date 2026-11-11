// 讯飞 ASR / TTS 协议单测：全部用假 socket，不发任何网络请求。
// 其中签名断言直接对齐官方文档给出的示例值，防止改坏 HMAC 拼接规则。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart';

class _FakeSocket implements XfyunSocket {
  _FakeSocket(this.replies);

  final List<String> replies;
  final List<String> sent = <String>[];
  final StreamController<String> _controller = StreamController<String>();
  bool closed = false;
  bool _replied = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String text) {
    sent.add(text);
    if (_replied) {
      return;
    }
    _replied = true;
    for (final String reply in replies) {
      _controller.add(reply);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

XfyunSocketOpener _openerFor(_FakeSocket socket, List<Uri> seen) =>
    (Uri uri) async {
      seen.add(uri);
      return socket;
    };

SpeechConfig _config() => SpeechConfig(
      appId: 'test-app',
      apiKey: 'test-key',
      apiSecret: 'test-secret',
      ugVcn: 'x4_ug_test',
      zhVcn: 'x4_xiaoyan',
    );

String _encodedWords(List<String> words) => base64.encode(utf8.encode(
      jsonEncode(<String, Object>{
        'sn': 1,
        'ws': <Object>[
          for (final String word in words)
            <String, Object>{
              'cw': <Object>[
                <String, Object>{'w': word},
              ],
            },
        ],
      }),
    ));

String _asrFrame(String encoded, int status) => jsonEncode(<String, Object>{
      'header': <String, Object>{
        'code': 0,
        'message': 'success',
        'status': status,
      },
      'payload': <String, Object>{
        'result': <String, Object>{'text': encoded, 'status': status},
      },
    });

String _ttsFrame(List<int> bytes, int status) =>
    jsonEncode(<String, Object>{
      'code': 0,
      'message': 'success',
      'data': <String, Object>{
        'audio': base64.encode(bytes),
        'status': status,
      },
    });

void main() {
  test('RFC1123 GMT 时间格式符合官方鉴权要求', () {
    expect(
      buildXfyunDate(DateTime.utc(2024, 5, 14, 8, 43, 39)),
      'Tue, 14 May 2024 08:43:39 GMT',
    );
  });

  test('HMAC 签名与官方多语种识别文档示例一致', () {
    expect(
      buildXfyunSignature(
        host: 'iat.cn-huabei-1.xf-yun.com',
        path: '/v1',
        date: 'Tue, 14 May 2024 08:43:39 GMT',
        apiSecret: 'secretxxxxxxxx2df7900c09xxxxxxxx',
      ),
      'fgG1OuqkHU6l/hNZ6Zs466ci+jUvOQjSNKWkLhvSoNM=',
    );
  });

  test('authorization 是签名串的 base64，且包含全部固定字段', () {
    final String authorization = buildXfyunAuthorization(
      host: 'iat.cn-huabei-1.xf-yun.com',
      path: '/v1',
      date: 'Tue, 14 May 2024 08:43:39 GMT',
      apiKey: 'keyxxxxxxxx8ee279348519exxxxxxxx',
      apiSecret: 'secretxxxxxxxx2df7900c09xxxxxxxx',
    );
    final String decoded = utf8.decode(base64.decode(authorization));
    expect(decoded, contains('api_key="keyxxxxxxxx8ee279348519exxxxxxxx"'));
    expect(decoded, contains('algorithm="hmac-sha256"'));
    expect(decoded, contains('headers="host date request-line"'));
    expect(decoded, contains('signature="fgG1Ouqk'));
  });

  test('wss 地址带齐 host / date / authorization', () {
    final Uri uri = buildXfyunUri(
      host: XfyunSpeechPort.asrHost,
      path: XfyunSpeechPort.asrPath,
      date: 'Tue, 14 May 2024 08:43:39 GMT',
      apiKey: 'k',
      apiSecret: 's',
    );
    expect(uri.scheme, 'wss');
    expect(uri.host, XfyunSpeechPort.asrHost);
    expect(uri.path, XfyunSpeechPort.asrPath);
    expect(uri.queryParameters['host'], XfyunSpeechPort.asrHost);
    expect(uri.queryParameters['date'], 'Tue, 14 May 2024 08:43:39 GMT');
    expect(uri.queryParameters['authorization'], isNotEmpty);
  });

  test('识别首帧指定维语 ug 与 16k PCM', () {
    final String payload = buildAsrFirstFrame(
      appId: 'app',
      ln: 'ug',
      audio: 'AAAA',
    );
    final Map<String, dynamic> frame =
        jsonDecode(payload) as Map<String, dynamic>;
    final Map<String, dynamic> parameter =
        frame['parameter'] as Map<String, dynamic>;
    final Map<String, dynamic> iat = parameter['iat'] as Map<String, dynamic>;
    expect(iat['ln'], 'ug');
    expect(iat['domain'], 'slm');
    expect(iat['language'], 'mul_cn');
    final Map<String, dynamic> payloadBody =
        frame['payload'] as Map<String, dynamic>;
    final Map<String, dynamic> audio =
        payloadBody['audio'] as Map<String, dynamic>;
    expect(audio['sample_rate'], 16000);
    expect(audio['bit_depth'], 16);
    expect(audio['encoding'], 'raw');
  });

  test('后续帧不带 parameter，末帧 status=2', () {
    final Map<String, dynamic> middle = jsonDecode(
      buildAsrAudioFrame(appId: 'app', status: 1, audio: 'AAAA'),
    ) as Map<String, dynamic>;
    expect(middle.containsKey('parameter'), isFalse);
    expect((middle['header'] as Map<String, dynamic>)['status'], 1);
    final Map<String, dynamic> last = jsonDecode(
      buildAsrAudioFrame(appId: 'app', status: 2, audio: ''),
    ) as Map<String, dynamic>;
    expect((last['header'] as Map<String, dynamic>)['status'], 2);
  });

  test('PCM 按 1280 字节切帧且无损', () {
    final Uint8List pcm = Uint8List.fromList(
      List<int>.generate(3000, (int index) => index % 251),
    );
    final List<String> frames = buildAsrAudioFrames(pcm);
    expect(frames.length, 3);
    int total = 0;
    for (final String frame in frames) {
      total += base64.decode(frame).length;
    }
    expect(total, 3000);
    expect(buildAsrAudioFrames(Uint8List(0)), <String>['']);
  });

  test('听写结果按 ws.cw.w 顺序拼接', () {
    expect(decodeAsrText(_encodedWords(<String>['你', '好'])), '你好');
    expect(decodeAsrText(''), isEmpty);
    expect(decodeAsrText('not-base64'), isEmpty);
  });

  test('识别帧解析：正常、错误码、非法 JSON', () {
    final AsrFrame ok = parseAsrMessage(_asrFrame(_encodedWords(<String>['你好']), 2));
    expect(ok.text, '你好');
    expect(ok.done, isTrue);
    expect(ok.code, 0);

    final AsrFrame bad = parseAsrMessage(jsonEncode(<String, Object>{
      'header': <String, Object>{
        'code': 10160,
        'message': 'no license',
        'status': 2,
      },
    }));
    expect(bad.code, 10160);
    expect(bad.text, isEmpty);
    expect(bad.done, isTrue);
    expect(parseAsrMessage('oops').code, -1);
  });

  test('合成请求用 UTF8 编码维文，避免 latin1 请求体问题', () {
    final Map<String, dynamic> request = jsonDecode(
      buildTtsRequest(appId: 'app', vcn: 'x4_ug', text: 'ياخشىمۇسىز'),
    ) as Map<String, dynamic>;
    final Map<String, dynamic> business =
        request['business'] as Map<String, dynamic>;
    expect(business['vcn'], 'x4_ug');
    expect(business['tte'], 'UTF8');
    expect(business['aue'], 'lame');
    expect(business['sfl'], 1);
    final Map<String, dynamic> data = request['data'] as Map<String, dynamic>;
    expect(
      utf8.decode(base64.decode(data['text'] as String)),
      'ياخشىمۇسىز',
    );
  });

  test('raw 模式不带 sfl，用于 CI 的 TTS→ASR 闭环', () {
    final Map<String, dynamic> request = jsonDecode(
      buildTtsRequest(appId: 'app', vcn: 'x4_zh', text: '你好', mp3: false),
    ) as Map<String, dynamic>;
    final Map<String, dynamic> business =
        request['business'] as Map<String, dynamic>;
    expect(business['aue'], 'raw');
    expect(business.containsKey('sfl'), isFalse);
  });

  test('合成响应按帧拼接音频，识别 11200 授权错误', () {
    final TtsFrame first = parseTtsMessage(_ttsFrame(<int>[1, 2], 1));
    expect(first.audio.toList(), <int>[1, 2]);
    expect(first.done, isFalse);
    final TtsFrame last = parseTtsMessage(_ttsFrame(<int>[3], 2));
    expect(last.audio.toList(), <int>[3]);
    expect(last.done, isTrue);
    final TtsFrame denied = parseTtsMessage(jsonEncode(<String, Object>{
      'code': 11200,
      'message': 'voice not authorized',
    }));
    expect(denied.code, 11200);
    expect(denied.done, isTrue);
    expect(parseTtsMessage('oops').code, -1);
  });

  test('listen 端到端：维语 ug、分包、拼接识别结果', () async {
    final _FakeSocket socket = _FakeSocket(<String>[
      _asrFrame(_encodedWords(<String>['你']), 1),
      _asrFrame(_encodedWords(<String>['好吗']), 2),
    ]);
    final List<Uri> seen = <Uri>[];
    final SpeechConfig config = _config();
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: config,
      opener: _openerFor(socket, seen),
      dateBuilder: () => 'Tue, 14 May 2024 08:43:39 GMT',
      frameDelay: Duration.zero,
    );
    final Uint8List pcm = Uint8List.fromList(List<int>.filled(3000, 0));
    expect(await port.listen(pcm, Language.uyghur), '你好吗');
    expect(seen.single.host, XfyunSpeechPort.asrHost);
    expect(socket.sent.length, 4);
    final Map<String, dynamic> first =
        jsonDecode(socket.sent.first) as Map<String, dynamic>;
    final Map<String, dynamic> iat =
        (first['parameter'] as Map<String, dynamic>)['iat']
            as Map<String, dynamic>;
    expect(iat['ln'], 'ug');
    expect(socket.closed, isTrue);
    expect(config.lastDiagnostic, isEmpty);
  });

  test('识别返回空文字时给出带音频时长的可诊断异常', () async {
    final _FakeSocket socket = _FakeSocket(<String>[_asrFrame('', 2)]);
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: _config(),
      opener: _openerFor(socket, <Uri>[]),
      dateBuilder: () => 'Tue, 14 May 2024 08:43:39 GMT',
      frameDelay: Duration.zero,
    );
    Object? caught;
    try {
      // 32000 字节 = 1 秒 16k/16bit 单声道 PCM。
      await port.listen(Uint8List(32000), Language.chinese);
    } on Object catch (error) {
      caught = error;
    }
    expect(caught, isA<SpeechException>());
    final String message = (caught! as SpeechException).message;
    expect(message, contains('云端没识别出文字'));
    expect(message, contains('1.0s'));
    expect(message, contains('源语言'));
    expect(socket.closed, isTrue);
  });

  test('speak 端到端：维语发音人、多帧音频合并', () async {
    final _FakeSocket socket = _FakeSocket(<String>[
      _ttsFrame(<int>[1, 2], 1),
      _ttsFrame(<int>[3], 2),
    ]);
    final List<Uri> seen = <Uri>[];
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: _config(),
      opener: _openerFor(socket, seen),
      dateBuilder: () => 'Tue, 14 May 2024 08:43:39 GMT',
    );
    final Uint8List audio = await port.speak(
      'ياخشىمۇسىز',
      Language.uyghur,
    );
    expect(audio.toList(), <int>[1, 2, 3]);
    expect(seen.single.host, XfyunSpeechPort.ttsHost);
    final Map<String, dynamic> request =
        jsonDecode(socket.sent.single) as Map<String, dynamic>;
    expect(
      (request['business'] as Map<String, dynamic>)['vcn'],
      'x4_ug_test',
    );
    expect(socket.closed, isTrue);
  });

  test('未配置凭证时端口不可用且明确报错', () async {
    final SpeechConfig empty = SpeechConfig(
      appId: '',
      apiKey: '',
      apiSecret: '',
      ugVcn: '',
      zhVcn: '',
    );
    final XfyunSpeechPort port = XfyunSpeechPort(config: empty);
    expect(port.isAvailable, isFalse);
    await expectLater(
      port.listen(Uint8List(1), Language.chinese),
      throwsA(isA<SpeechException>()),
    );
    expect(empty.canSpeak(true), isFalse);
    expect(empty.canSpeak(false), isFalse);
  });

  test('维语发音人未开通时只影响朗读，不影响识别配置', () {
    final SpeechConfig config = SpeechConfig(
      appId: 'a',
      apiKey: 'b',
      apiSecret: 'c',
      ugVcn: '',
      zhVcn: 'x4_xiaoyan',
    );
    expect(config.hasConfig, isTrue);
    expect(config.canSpeak(false), isTrue);
    expect(config.canSpeak(true), isFalse);
  });
}
