// 语音翻译端到端回归：把「点一下说话 → 再点结束 → 出译文 → 朗读」整条链路自动化。
//
// 分两层，都不需要真人参与：
//   1) E2E_LIVE=1 且凭证齐全时，用真实凭证跑 App 的真实端口与翻译链：
//      讯飞 TTS 先合成 16k PCM 冒充麦克风输入，再走 ASR → 小牛 MT → TTS。
//      这样连「录音字节格式是否真能被识别」也一并验证，而不只是验协议帧。
//   2) 无论有没有凭证，都用上一层的结果（或固定脚本数据）驱动 widget 测试，
//      断言开始/结束录音、两条气泡、自动朗读、手动朗读按钮真实生效。
//
// 之所以拆两层：widget 测试跑在 fake async 里，真实 WebSocket 不会完成；
// 而只用假实现又验不到云端。两层相加 = 真实服务 + 真实 UI 编排，且 CI 稳定。
// 凭证只从 CI 环境变量读取，不写仓库、不进产物、不打印、不进批注。

import 'dart:io' show HttpOverrides, Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/conversation_page.dart';
import 'package:uyghur_interpreter/default_speech.dart';
import 'package:uyghur_interpreter/default_translator.dart';
import 'package:uyghur_interpreter/device_audio.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/speech_pipeline.dart';
import 'package:uyghur_interpreter/translation_config.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart';

Uint8List _scriptAudio() => Uint8List.fromList(
      List<int>.filled(4096, 0),
    );

void main() {
  final Map<String, String> env = Platform.environment;
  final String xfAppId = env['XFYUN_APP_ID'] ?? '';
  final String xfKey = env['XFYUN_API_KEY'] ?? '';
  final String xfSecret = env['XFYUN_API_SECRET'] ?? '';
  final String ugVcn = env['XFYUN_UG_VCN'] ?? '';
  final String zhVcn = env['XFYUN_ZH_VCN'] ?? '';
  final String niuAppId = env['NIUTRANS_APP_ID'] ?? '';
  final String niuKey = env['NIUTRANS_API_KEY'] ?? '';
  final String ugCode = (env['NIUTRANS_UG_CODE'] ?? '').trim();
  final bool live = env['E2E_LIVE'] == '1';
  final bool ready = live &&
      xfAppId.isNotEmpty &&
      xfKey.isNotEmpty &&
      xfSecret.isNotEmpty &&
      niuAppId.isNotEmpty &&
      niuKey.isNotEmpty;

  // 真实链路的结果回灌给 widget 测试，让 UI 用例也用「真数据」而不是编造的常量。
  SpeechTurn? zhTurn;
  SpeechTurn? ugTurn;
  Uint8List? zhPcm;
  Uint8List? ugPcm;

  if (ready) {
    // flutter_test 默认装了拦截网络的 HttpOverrides，这里强制真实连接。
    HttpOverrides.global = null;
    speechConfig.appId = xfAppId;
    speechConfig.apiKey = xfKey;
    speechConfig.apiSecret = xfSecret;
    speechConfig.ugVcn = ugVcn;
    speechConfig.zhVcn = zhVcn.isEmpty ? 'x4_xiaoyan' : zhVcn;
    translationConfig.provider = TranslationProvider.niuTrans;
    translationConfig.appId = niuAppId;
    translationConfig.key = niuKey;
    translationConfig.ugCode = ugCode.isEmpty ? 'uy' : ugCode;
  }

  if (ready) {
    test('E2E 真实链路：中文语音 → 维文译文 → 维语朗读', () async {
      // 用 TTS 造一段真实语音当「录音」，避免依赖 CI runner 上的物理麦克风。
      final XfyunSpeechPort source =
          XfyunSpeechPort(config: speechConfig, ttsMp3: false);
      zhPcm = await source.speak('你好', Language.chinese);
      expect(zhPcm!.length, greaterThan(1000),
          reason: '合成的 PCM 太短，无法充当录音输入');

      // 这里刻意用 App 的默认端口与默认翻译链，覆盖设置页保存后的真实路径。
      final SpeechPipeline pipeline = SpeechPipeline(
        speech: const ConfigurableSpeechPort(),
        translator: buildDefaultTranslator(),
      );
      zhTurn = await pipeline.run(zhPcm!, TranslationDirection.zhToUg);

      final SpeechTurn turn = zhTurn!;
      expect(turn.heard.contains('你好'), isTrue,
          reason: 'ASR 没识别出合成的中文语音');
      expect(turn.translation.found, isTrue,
          reason: '小牛未返回译文：${translationConfig.lastDiagnostic}');
      expect(turn.translation.isDemo, isFalse,
          reason: '落到了演示词库，说明云端翻译没生效');
      expect(turn.translation.text.trim(), isNotEmpty);
      expect(turn.hasAudio, isTrue, reason: '译文没有生成朗读音频');
      // CI 靠这一行写 ::notice:: 批注，故显式豁免 avoid_print；不输出任何凭证。
      // ignore: avoid_print
      print('E2E live check: 中文识别=${turn.heard} '
          '译文=${turn.translation.text} provider=${turn.translation.provider} '
          '录音=${zhPcm!.length}字节 朗读=${turn.audio.length}字节');
    });
  } else {
    test('E2E 真实链路（本轮不跑：E2E_LIVE 未开或凭证不全）', () {
      expect(ready, isFalse);
    });
  }

  if (ready && ugVcn.trim().isNotEmpty) {
    test('E2E 真实链路：维语语音 → 中文译文 → 中文朗读', () async {
      final XfyunSpeechPort source =
          XfyunSpeechPort(config: speechConfig, ttsMp3: false);
      ugPcm = await source.speak('ياخشىمۇسىز', Language.uyghur);
      expect(ugPcm!.length, greaterThan(1000));

      final SpeechPipeline pipeline = SpeechPipeline(
        speech: const ConfigurableSpeechPort(),
        translator: buildDefaultTranslator(),
      );
      ugTurn = await pipeline.run(ugPcm!, TranslationDirection.ugToZh);

      final SpeechTurn turn = ugTurn!;
      expect(turn.heard.trim(), isNotEmpty);
      expect(turn.translation.found, isTrue,
          reason: '小牛未返回中文译文：${translationConfig.lastDiagnostic}');
      expect(turn.translation.isDemo, isFalse);
      expect(turn.translation.text.trim(), isNotEmpty);
      expect(turn.hasAudio, isTrue);
      // ignore: avoid_print
      print('E2E live check: 维语识别=${turn.heard} '
          '译文=${turn.translation.text} provider=${turn.translation.provider} '
          '录音=${ugPcm!.length}字节 朗读=${turn.audio.length}字节');
    });
  }

  testWidgets('E2E UI：点击说话 → 识别/译文气泡 → 自动朗读 → 手动朗读',
      (WidgetTester tester) async {
    final SpeechTurn? turn = zhTurn;
    final String heard = turn?.heard ?? '你好。';
    final String translated = turn?.translation.text ?? 'ياخشىمۇسىز';
    final Uint8List audio = turn?.audio ?? _scriptAudio();
    final _FakeAudioPort mic = _FakeAudioPort(zhPcm ?? _scriptAudio());

    await tester.pumpWidget(MaterialApp(
      home: ConversationPage(
        speech: _ReplaySpeechPort(heard: heard, audio: audio),
        translator: _ReplayTranslator(translated),
        audio: mic,
      ),
    ));

    final Finder voice = find.byWidgetPredicate(
      (Widget widget) => widget is TextButton,
    );
    expect(voice, findsOneWidget);
    expect(tester.widget<TextButton>(voice).onPressed, isNotNull,
        reason: '语音端口可用时按钮必须能点');

    await tester.tap(voice);
    await tester.pumpAndSettle();
    expect(mic.starts, 1);
    // 「正在录音」同时出现在 notice 和按钮 label 里，用按钮的精确文案断言状态切换。
    expect(find.text('正在录音 · 点击结束'), findsOneWidget);

    await tester.tap(voice);
    await tester.pumpAndSettle();
    expect(mic.stops, 1);
    expect(find.text(heard), findsOneWidget, reason: '识别原文气泡缺失');
    expect(find.text(translated), findsOneWidget, reason: '译文气泡缺失');
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
    final SpeechTurn? turn = ugTurn;
    final String heard = turn?.heard ?? 'ياخشىمۇسىز';
    final String translated = turn?.translation.text ?? '你好';
    final Uint8List audio = turn?.audio ?? _scriptAudio();
    final _FakeAudioPort mic = _FakeAudioPort(ugPcm ?? _scriptAudio());

    await tester.pumpWidget(MaterialApp(
      home: ConversationPage(
        speech: _ReplaySpeechPort(heard: heard, audio: audio),
        translator: _ReplayTranslator(translated),
        audio: mic,
      ),
    ));

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.textContaining('ئۇيغۇرچە → 中文'), findsOneWidget);

    final Finder voice = find.byWidgetPredicate(
      (Widget widget) => widget is TextButton,
    );
    await tester.tap(voice);
    await tester.pumpAndSettle();
    await tester.tap(voice);
    await tester.pumpAndSettle();

    expect(find.text(heard), findsOneWidget);
    expect(find.text(translated), findsOneWidget);
    expect(mic.played.length, 1);
  });
}

/// 假录音 / 播放端口：只记录调用，不触碰 record / audioplayers 平台通道。
class _FakeAudioPort implements AudioPort {
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

class _ReplayTranslator implements Translator {
  const _ReplayTranslator(this.translated);

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
