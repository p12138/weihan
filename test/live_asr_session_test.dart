// 边录边传会话的协议单测：全部用假 socket，不发任何网络请求。
//
// 这里钉住三件最容易改坏的事：
//   1. 发帧仍是 40ms / 1280 字节的官方实时率（曾经压到 10ms 真机识别空）；
//   2. 音频在「说话过程中」就发出去了，松手只补尾帧和结束帧；
//   3. 取消不补结束帧，关连接不会把整轮结果拖住。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/live_asr.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart';

const String _fixedDate = 'Tue, 14 May 2024 08:43:39 GMT';

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

/// 服务端收到 status=2 结束帧才回最终结果，和真实 RTASR 行为一致。
class _SessionSocket implements XfyunSocket {
  _SessionSocket(this.words);

  final List<String> words;
  final List<String> sent = <String>[];
  final StreamController<String> _controller = StreamController<String>();
  bool closed = false;
  bool _answered = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String text) {
    sent.add(text);
    final Map<String, dynamic> frame =
        jsonDecode(text) as Map<String, dynamic>;
    final Map<String, dynamic> header =
        frame['header'] as Map<String, dynamic>;
    if (header['status'] == 2 && !_answered) {
      _answered = true;
      _controller.add(_asrFrame(_encodedWords(words), 2));
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

class _NeverCloseSocket implements XfyunSocket {
  @override
  Stream<String> get messages => const Stream<String>.empty();

  @override
  void send(String text) {}

  /// 永不回 close frame，模拟服务端不配合时 dart:io 的行为。
  @override
  Future<void> close() => Completer<void>().future;
}

Map<String, dynamic> _frame(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

int _status(String raw) =>
    (_frame(raw)['header'] as Map<String, dynamic>)['status'] as int;

void main() {
  test('边录边传：整帧边录边发，松手只补尾帧与结束帧', () async {
    final _SessionSocket socket = _SessionSocket(<String>['你好', '吗']);
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: _config(),
      opener: (Uri uri) async => socket,
      dateBuilder: () => _fixedDate,
      frameDelay: Duration.zero, // 用例里不真的睡 40ms
    );

    final LiveAsrSession session = port.openLiveAsr(Language.chinese);
    session.add(Uint8List(2560)); // 2 个整帧
    session.add(Uint8List(1280)); // 1 个整帧
    session.add(Uint8List(500)); // 不足一帧，留到 finish 补发

    expect(await session.finish(), '你好吗');
    expect(socket.sent.length, 5,
        reason: '首帧 + 2 个中间帧 + 尾帧 + 结束帧');
    expect(_status(socket.sent.first), 0, reason: '首帧带业务参数');
    expect(_status(socket.sent[1]), 1);
    expect(_status(socket.sent[2]), 1);
    expect(_status(socket.sent[3]), 1, reason: '不足一帧的余量也要发');
    expect(_status(socket.sent.last), 2, reason: '最后才是结束帧');

    final Map<String, dynamic> first = _frame(socket.sent.first);
    final Map<String, dynamic> iat =
        (first['parameter'] as Map<String, dynamic>)['iat']
            as Map<String, dynamic>;
    expect(iat['ln'], 'zh');
    // 首帧 audio 是 1280 字节 PCM 的 base64。
    final String audio = ((first['payload'] as Map<String, dynamic>)['audio']
        as Map<String, dynamic>)['audio'] as String;
    expect(base64.decode(audio).length, 1280);
    expect(socket.closed, isTrue);
  });

  test('发帧按 40ms 时间轴推进，不是一次性灌给服务端', () async {
    final _SessionSocket socket = _SessionSocket(<String>['你好']);
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: _config(),
      opener: (Uri uri) async => socket,
      dateBuilder: () => _fixedDate,
      frameDelay: const Duration(milliseconds: 40),
    );

    final LiveAsrSession session = port.openLiveAsr(Language.chinese);
    session.add(Uint8List(3840)); // 3 帧 → 时间轴 0 / 40 / 80ms
    final Stopwatch watch = Stopwatch()..start();
    expect(await session.finish(), '你好');
    watch.stop();

    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(60),
        reason: '10ms 全速灌曾让真机只吃到前半段，不能回退');
    expect(socket.sent.length, 4, reason: '3 个数据帧 + 1 个结束帧');
  });

  test('上滑取消：不补结束帧，会话立即关闭', () async {
    final _SessionSocket socket = _SessionSocket(<String>['你好']);
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: _config(),
      opener: (Uri uri) async => socket,
      dateBuilder: () => _fixedDate,
      frameDelay: Duration.zero,
    );

    final LiveAsrSession session = port.openLiveAsr(Language.chinese);
    // 先让建连的微任务跑完，再验证取消路径。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    session.add(Uint8List(2560));
    await session.cancel();

    expect(socket.sent.where((String raw) => _status(raw) == 2), isEmpty,
        reason: '取消不该向云端提交结束帧，更不该产生一次识别');
    expect(socket.closed, isTrue);
  });

  test('连不上时 finish 抛可读异常，交给 pipeline 回退老路', () async {
    final XfyunSpeechPort port = XfyunSpeechPort(
      config: _config(),
      opener: (Uri uri) async =>
          throw const SpeechException('连接讯飞服务超时（12 秒）'),
      dateBuilder: () => _fixedDate,
      frameDelay: Duration.zero,
    );
    final LiveAsrSession session = port.openLiveAsr(Language.chinese);
    session.add(Uint8List(1280));

    await expectLater(
      session.finish(),
      throwsA(isA<SpeechException>().having(
        (SpeechException error) => error.message,
        'message',
        contains('识别连接失败'),
      )),
    );
  });

  test('服务端不回 close frame 时，收尾最多等 400ms 而不是 3 秒', () async {
    final Stopwatch watch = Stopwatch()..start();
    await closeXfyunSocket(_NeverCloseSocket());
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(1500),
        reason: '每轮 ASR + TTS 各一次，白等 3 秒会直接拖慢整轮翻译');
  });
}
