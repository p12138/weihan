// 语音 UI 端到端回归：自动点「开始说话 / 结束」、检查两条气泡与两次朗读。
//
// 这个文件里**只有 testWidgets**，不发任何网络请求，所以每次 push 都能稳定跑。
// 真实云端三环在 test/live_speech_pipeline_test.dart（不能混进本文件，否则
// TestWidgetsFlutterBinding 的 fake async 会让真实 WebSocket 永远等不到完成）。
// 若上一层的真实结果文件存在，就用真实识别文本 / 译文回放给 UI；
// 不存在（本地开发、普通 push）则用固定脚本数据，行为完全等价。

import 'dart:convert' show jsonDecode;
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/conversation_page.dart';
import 'package:uyghur_interpreter/device_audio.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart' show SpeechException;

const String _resultPath = '/tmp/weihan_e2e.json';

Map<String, dynamic> _liveResults() {
  try {
    final File file = File(_resultPath);
    if (!file.existsSync()) {
      return const <String, dynamic>{};
    }
    final Object? decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
  } on Object {
    return const <String, dynamic>{};
  }
}

Uint8List _scriptAudio() => Uint8List.fromList(
      List<int>.filled(4096, 0),
    );

void main() {
  final Map<String, dynamic> live = _liveResults();
  // 配齐 Secret 跑过真实三环时，UI 用例读到的就是真识别文本 / 真译文。
  final String zhHeard = (live['zh_heard'] as String?) ?? '你好。';
  final String zhTranslated =
      (live['zh_translated'] as String?) ?? 'ياخشىمۇسىز';
  final String ugHeard = (live['ug_heard'] as String?) ?? 'ياخشىمۇسىز';
  final String ugTranslated = (live['ug_translated'] as String?) ?? '你好';
  final Uint8List scriptAudio = _scriptAudio();

  testWidgets('E2E UI：按住说话 → 识别/译文气泡 → 自动朗读 → 手动朗读',
      (WidgetTester tester) async {
    final _FakeAudioPort mic = _FakeAudioPort(scriptAudio);

    await tester.pumpWidget(MaterialApp(
      home: ConversationPage(
        speech: _ReplaySpeechPort(heard: zhHeard, audio: scriptAudio),
        translator: _ReplayTranslator(zhTranslated),
        audio: mic,
      ),
    ));

    final Finder voice = find.byKey(const ValueKey<String>('voice-button'));
    expect(voice, findsOneWidget);
    expect(find.text('按住说话 · 松手翻译'), findsOneWidget);

    // 按住说话：按下当场开始录音，松手才结束 —— 不需要再点第二次。
    final TestGesture hold = await tester.startGesture(tester.getCenter(voice));
    await tester.pump();
    await tester.pump();
    expect(mic.starts, 1, reason: '按下应立即开始录音');
    // 「正在录音」同时出现在 notice 和按钮 label 里，用按钮的精确文案断言状态切换。
    expect(find.text('松手结束 · 正在录音'), findsOneWidget);

    await hold.up();
    await tester.pumpAndSettle();
    expect(mic.stops, 1);
    expect(find.text(zhHeard), findsOneWidget, reason: '识别原文气泡缺失');
    expect(find.text(zhTranslated), findsOneWidget, reason: '译文气泡缺失');
    expect(find.textContaining('识别到'), findsOneWidget);
    expect(mic.played.length, 1, reason: '译文应自动朗读一次');
    expect(mic.played.single.length, greaterThan(1000));

    // 译文气泡右侧的朗读按钮：再播一次，且不影响已有消息。
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    expect(mic.played.length, 2, reason: '朗读按钮没有触发播放');
  });

  testWidgets('E2E UI：切到维语→中文后仍走完整三环',
      (WidgetTester tester) async {
    final _FakeAudioPort mic = _FakeAudioPort(scriptAudio);

    await tester.pumpWidget(MaterialApp(
      home: ConversationPage(
        speech: _ReplaySpeechPort(heard: ugHeard, audio: scriptAudio),
        translator: _ReplayTranslator(ugTranslated),
        audio: mic,
      ),
    ));

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.textContaining('ئۇيغۇرچە → 中文'), findsOneWidget);

    final Finder voice = find.byKey(const ValueKey<String>('voice-button'));
    final TestGesture hold = await tester.startGesture(tester.getCenter(voice));
    await tester.pump();
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();

    expect(find.text(ugHeard), findsOneWidget);
    expect(find.text(ugTranslated), findsOneWidget);
    expect(mic.played.length, 1);
  });

  // 维语发音人没开通时：文字照常出，只是多一行「朗读失败」，绝不静默。
  testWidgets('E2E UI：朗读失败不吞译文，并说明原因', (WidgetTester tester) async {
    final _FakeAudioPort mic = _FakeAudioPort(scriptAudio);

    await tester.pumpWidget(MaterialApp(
      home: ConversationPage(
        speech: _BrokenSpeakPort(heard: zhHeard),
        translator: _ReplayTranslator(zhTranslated),
        audio: mic,
      ),
    ));

    final Finder voice = find.byKey(const ValueKey<String>('voice-button'));
    final TestGesture hold = await tester.startGesture(tester.getCenter(voice));
    await tester.pump();
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();

    expect(find.text(zhHeard), findsOneWidget, reason: '识别原文不该丢');
    expect(find.text(zhTranslated), findsOneWidget, reason: '译文不该丢');
    expect(find.textContaining('朗读失败'), findsOneWidget);
    expect(mic.played, isEmpty, reason: '没有音频就不该调用播放');
  });

  // 录音时浮出音量面板；没有音量流（假实现）也要稳定渲染、不卡住。
  testWidgets('E2E UI：录音时浮出音量面板', (WidgetTester tester) async {
    final _FakeAudioPort mic = _FakeAudioPort(scriptAudio);

    await tester.pumpWidget(MaterialApp(
      home: ConversationPage(
        speech: _ReplaySpeechPort(heard: zhHeard, audio: scriptAudio),
        translator: _ReplayTranslator(zhTranslated),
        audio: mic,
      ),
    ));

    final Finder voice = find.byKey(const ValueKey<String>('voice-button'));
    expect(find.text('松手结束'), findsNothing, reason: '没录音时不该有浮层');

    final TestGesture hold = await tester.startGesture(tester.getCenter(voice));
    await tester.pumpAndSettle();
    expect(mic.starts, 1);
    expect(find.text('松手结束'), findsOneWidget);

    await hold.up();
    await tester.pumpAndSettle();
    expect(find.text('松手结束'), findsNothing, reason: '松手后浮层要收起来');
  });
}

/// 假录音 / 播放端口：只记录调用，不触碰 record / audioplayers 平台通道。
///
/// 用 extends 而不是 implements：`levels` / `dispose` 在 AudioPort 里有默认实现，
/// implements 只会继承签名、拿不到实现，得把两个成员都重写一遍。
class _FakeAudioPort extends AudioPort {
  _FakeAudioPort(this.recorded);

  final Uint8List recorded;
  final List<Uint8List> played = <Uint8List>[];
  int starts = 0;
  int stops = 0;

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

/// 把真实链路（或脚本）结果回放给 UI，保证 widget 测试不发网络也确定性可跑。
class _ReplaySpeechPort implements SpeechPort {
  const _ReplaySpeechPort({required this.heard, required this.audio});

  final String heard;
  final Uint8List audio;

  @override
  bool get isAvailable => true;

  @override
  Future<String> listen(Uint8List pcm, Language language) async => heard;

  @override
  Future<Uint8List> speak(String text, Language language) async => audio;
}

/// 识别正常、合成失败：模拟维语发音人未开通 / 额度用尽。
class _BrokenSpeakPort implements SpeechPort {
  const _BrokenSpeakPort({required this.heard});

  final String heard;

  @override
  bool get isAvailable => true;

  @override
  Future<String> listen(Uint8List pcm, Language language) async => heard;

  @override
  Future<Uint8List> speak(String text, Language language) async {
    throw const SpeechException('维语发音人 vcn 未配置 · 到设置页填写');
  }
}

class _ReplayTranslator implements Translator {  const _ReplayTranslator(this.translated);

  final String translated;

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async =>
      Translation(
        text: translated,
        provider: 'E2E 回放',
        found: true,
        isDemo: false,
      );
}
