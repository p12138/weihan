// 「上滑取消」回归：说错了重说一遍，不该产生消息、也不该白跑一次云端。
//
// 覆盖三件事：
//   1. 上滑过阈值 → 浮层与按钮都变成「松开取消」；
//   2. 此时松手 → 停录音、丢 PCM、识别/翻译/朗读一次都不调用；
//   3. 滑回来（或只是横向挪手指）→ 照常走完整的翻译链路。

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/conversation_page.dart';
import 'package:uyghur_interpreter/device_audio.dart';

final Uint8List _pcm = Uint8List.fromList(List<int>.filled(4096, 0));
const Offset _swipeUp = Offset(0, -160);

const ValueKey<String> _voiceKey = ValueKey<String>('voice-button');

void main() {
  test('取消阈值要够得着又不至于误触', () {
    expect(kCancelDragDistance, greaterThan(60));
    expect(kCancelDragDistance, lessThan(160));
  });

  testWidgets('上滑进取消区后松手：丢弃录音，不调用云端三环',
      (WidgetTester tester) async {
    final _FakeAudio mic = _FakeAudio(_pcm);
    final _CountingSpeech speech = _CountingSpeech('你好');
    final _CountingTranslator translator = _CountingTranslator();

    await _pumpPage(tester, mic, speech, translator);

    final TestGesture hold =
        await tester.startGesture(tester.getCenter(find.byKey(_voiceKey)));
    await tester.pump();
    await tester.pump();
    expect(mic.starts, 1);
    expect(find.text('手指上滑，取消发送'), findsOneWidget);
    expect(find.text('松手结束'), findsOneWidget);

    await hold.moveBy(_swipeUp);
    await tester.pump();
    expect(find.text('松开手指，取消发送'), findsOneWidget,
        reason: '取消胶囊要给出明确回执');
    expect(find.text('松开手指 · 取消发送'), findsOneWidget,
        reason: '按钮文案也要跟着变');
    expect(find.text('滑回下方继续说话'), findsOneWidget);
    expect(find.text('松手结束'), findsNothing);

    await hold.up();
    await tester.pumpAndSettle();

    expect(mic.stops, 1, reason: '取消也要停掉录音，不能留着麦克风');
    expect(speech.listens, 0, reason: '取消不该调用识别');
    expect(speech.speaks, 0, reason: '取消不该合成语音');
    expect(translator.calls, 0, reason: '取消不该调用翻译');
    expect(mic.played, isEmpty, reason: '取消不该播放');
    expect(find.text('录音已取消 · 没有发送'), findsOneWidget);
    expect(find.text('你好'), findsNothing, reason: '不该留下气泡');
    expect(find.text('手指上滑，取消发送'), findsNothing,
        reason: '浮层要跟着收起来');
  });

  testWidgets('从取消区滑回来再松手：照常识别、翻译、朗读',
      (WidgetTester tester) async {
    final _FakeAudio mic = _FakeAudio(_pcm);
    final _CountingSpeech speech = _CountingSpeech('你好');
    final _CountingTranslator translator = _CountingTranslator();

    await _pumpPage(tester, mic, speech, translator);

    final TestGesture hold =
        await tester.startGesture(tester.getCenter(find.byKey(_voiceKey)));
    await tester.pump();
    await tester.pump();

    await hold.moveBy(_swipeUp);
    await tester.pump();
    expect(find.text('松开手指，取消发送'), findsOneWidget);

    await hold.moveBy(const Offset(0, 160));
    await tester.pump();
    expect(find.text('手指上滑，取消发送'), findsOneWidget,
        reason: '滑回来要退出取消态');
    expect(find.text('松手结束'), findsOneWidget);

    await hold.up();
    await tester.pumpAndSettle();

    expect(speech.listens, 1);
    expect(translator.calls, 1);
    expect(mic.played.length, 1);
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('录音已取消 · 没有发送'), findsNothing);
  });

  testWidgets('只是横向挪手指不会误判成取消', (WidgetTester tester) async {
    final _FakeAudio mic = _FakeAudio(_pcm);
    final _CountingSpeech speech = _CountingSpeech('你好');
    final _CountingTranslator translator = _CountingTranslator();

    await _pumpPage(tester, mic, speech, translator);

    final TestGesture hold =
        await tester.startGesture(tester.getCenter(find.byKey(_voiceKey)));
    await tester.pump();
    await tester.pump();

    await hold.moveBy(const Offset(140, 0));
    await tester.pump();
    expect(find.text('手指上滑，取消发送'), findsOneWidget);
    expect(find.text('松开手指，取消发送'), findsNothing);

    await hold.up();
    await tester.pumpAndSettle();
    expect(speech.listens, 1);
    expect(find.text('你好'), findsOneWidget);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeAudio mic,
  _CountingSpeech speech,
  _CountingTranslator translator,
) async {
  await tester.pumpWidget(MaterialApp(
    home: ConversationPage(
      speech: speech,
      translator: translator,
      audio: mic,
    ),
  ));
}

class _FakeAudio extends AudioPort {
  _FakeAudio(this.recorded);

  final Uint8List recorded;
  int starts = 0;
  int stops = 0;
  final List<Uint8List> played = <Uint8List>[];

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> startRecord() async {
    starts += 1;
  }

  @override
  Future<Uint8List> stopRecord() async {
    stops += 1;
    return recorded;
  }

  @override
  Future<void> play(Uint8List audio) async {
    played.add(audio);
  }
}

class _CountingSpeech implements SpeechPort {
  _CountingSpeech(this.heard);

  final String heard;
  int listens = 0;
  int speaks = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<String> listen(Uint8List pcm, Language language) async {
    listens += 1;
    return heard;
  }

  @override
  Future<Uint8List> speak(String text, Language language) async {
    speaks += 1;
    return Uint8List(4096);
  }
}

class _CountingTranslator implements Translator {
  int calls = 0;

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    calls += 1;
    return Translation(
      text: 'ياخشىمۇسىز',
      provider: '取消测试',
      found: true,
      isDemo: false,
    );
  }
}
