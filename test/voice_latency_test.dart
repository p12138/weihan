// 翻译等待时长的回归：文字什么时候上屏、音频什么时候上传。
//
// 真机反馈「翻译的等待时间太长」。老链路要把整段 PCM 按 40ms/帧实时率在
// 松手后重放一遍（说 5 秒就再等 5 秒），还要等 TTS 合成完才一次性上屏。
// 这里把两件事钉死：① 录音过程中音频就已经在传，松手不再整段重传；
// ② 译文一返回就上屏，合成朗读卡住也不能挡住文字。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/conversation_page.dart';
import 'package:uyghur_interpreter/device_audio.dart';
import 'package:uyghur_interpreter/live_asr.dart';

const ValueKey<String> _voiceKey = ValueKey<String>('voice-button');
const Offset _swipeUp = Offset(0, -160);

final Uint8List _pcm = Uint8List.fromList(List<int>.filled(4096, 0));

void main() {
  testWidgets('按住时 PCM 已在上传，松手直接用会话结果、不整段重传',
      (WidgetTester tester) async {
    final _ChunkAudioFake mic = _ChunkAudioFake();
    final _LiveSpeechFake speech = _LiveSpeechFake();
    await _pumpPage(tester, mic, speech);

    final TestGesture hold =
        await tester.startGesture(tester.getCenter(find.byKey(_voiceKey)));
    await tester.pump();
    await tester.pump();

    expect(speech.session.chunks.length, 2,
        reason: '说话过程中的 PCM 必须已经交给识别会话');
    expect(speech.listens, 0);

    await hold.up();
    await tester.pumpAndSettle();

    expect(speech.session.finishes, 1);
    expect(speech.listens, 0, reason: '边录边传成功时不能再花一个说话时长重传');
    expect(find.text('你好'), findsOneWidget);
    expect(mic.played.length, 1);
  });

  // 「译文不等 TTS 上屏」由 speech_pipeline_test.dart 的纯 Dart 顺序单测钉住：
  // widget 层用永不完成的 Completer 卡住合成会让 fake async 挂起，测试不可靠。

  testWidgets('会话云端没认出字时自动整段重传，不让用户白说一遍',
      (WidgetTester tester) async {
    final _ChunkAudioFake mic = _ChunkAudioFake();
    final _LiveSpeechFake speech = _LiveSpeechFake(liveResult: '');
    await _pumpPage(tester, mic, speech);

    final TestGesture hold =
        await tester.startGesture(tester.getCenter(find.byKey(_voiceKey)));
    await tester.pump();
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();

    expect(speech.session.finishes, 1);
    expect(speech.listens, 1, reason: '边录边传空结果必须回退到完整 PCM 老路');
    expect(find.text('老路识别'), findsOneWidget);
    expect(mic.played.length, 1);
  });

  testWidgets('上滑取消：会话立刻丢弃，不补结束帧也不跑云端三环',
      (WidgetTester tester) async {
    final _ChunkAudioFake mic = _ChunkAudioFake();
    final _LiveSpeechFake speech = _LiveSpeechFake();
    await _pumpPage(tester, mic, speech);

    final TestGesture hold =
        await tester.startGesture(tester.getCenter(find.byKey(_voiceKey)));
    await tester.pump();
    await tester.pump();
    await hold.moveBy(_swipeUp);
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();

    expect(speech.session.cancels, 1);
    expect(speech.session.finishes, 0);
    expect(speech.listens, 0);
    expect(speech.speaks, 0);
    expect(mic.played, isEmpty);
    expect(find.text('录音已取消 · 没有发送'), findsOneWidget);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _ChunkAudioFake mic,
  _LiveSpeechFake speech,
) async {
  await tester.pumpWidget(MaterialApp(
    home: ConversationPage(
      speech: speech,
      translator: const _FixedTranslator(),
      audio: mic,
    ),
  ));
}

/// 真机端口的两个可选能力都具备：能吐 PCM 增量块。
class _ChunkAudioFake extends AudioPort implements ChunkedAudioPort {
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast(sync: true);
  final List<Uint8List> played = <Uint8List>[];
  int stops = 0;

  @override
  Stream<Uint8List> get pcmChunks => _chunks.stream;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> startRecord() async {
    // 模拟录音平台按块送裸 PCM；订阅在 startRecord 之前就建好了。
    _chunks.add(Uint8List(1280));
    _chunks.add(Uint8List(1280));
  }

  @override
  Future<Uint8List> stopRecord() async {
    stops += 1;
    return _pcm;
  }

  @override
  Future<void> play(Uint8List audio) async {
    played.add(audio);
  }

  @override
  void dispose() {
    if (!_chunks.isClosed) {
      _chunks.close();
    }
  }
}

class _LiveSessionFake implements LiveAsrSession {
  _LiveSessionFake(this.result);

  final String result;
  final List<Uint8List> chunks = <Uint8List>[];
  int finishes = 0;
  int cancels = 0;

  @override
  void add(Uint8List pcm) => chunks.add(pcm);

  @override
  Future<String> finish() async {
    finishes += 1;
    return result;
  }

  @override
  Future<void> cancel() async {
    cancels += 1;
  }
}

class _LiveSpeechFake implements SpeechPort, LiveSpeechPort {
  _LiveSpeechFake({this.liveResult = '你好'})
      : session = _LiveSessionFake(liveResult);

  final String liveResult;
  final _LiveSessionFake session;
  int listens = 0;
  int speaks = 0;

  @override
  bool get isAvailable => true;

  @override
  LiveAsrSession openLiveAsr(Language language) => session;

  @override
  Future<String> listen(Uint8List pcm, Language language) async {
    listens += 1;
    return '老路识别';
  }

  @override
  Future<Uint8List> speak(String text, Language language) async {
    speaks += 1;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}

class _FixedTranslator extends Translator {
  const _FixedTranslator();

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    return const Translation(
      text: 'ياخشىمۇسىز',
      provider: '低延迟测试',
      found: true,
      isDemo: false,
    );
  }
}
