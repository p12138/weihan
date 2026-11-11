// 真实云端的语音三环：TTS 造 PCM 冒充录音 → ASR → 小牛 MT → TTS。
//
// 这个文件里**只能有 test()，不能有 testWidgets()**：flutter_test 一旦在文件里
// 看到 testWidgets，就会为整个文件启用 TestWidgetsFlutterBinding 的 fake async，
// 真实 WebSocket / HttpClient 的 Future 永远不会被驱动，只会被拖到超时。
// run #38 的两个用例就是这样各卡满 3 分钟；UI 编排回归在 speech_e2e_test.dart。
//
// 跑完把真实识别文本与译文写进 /tmp 的结果文件，供 UI 层回放；
// 凭证只从 CI 环境变量读取，不写仓库、不进产物、不打印、不进批注。

import 'dart:convert' show jsonEncode;
import 'dart:io' show File, HttpOverrides, Platform;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/default_speech.dart';
import 'package:uyghur_interpreter/default_translator.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/speech_pipeline.dart';
import 'package:uyghur_interpreter/translation_config.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart';

const String _resultPath = '/tmp/weihan_e2e.json';

final Map<String, String> _results = <String, String>{};

void _flushResults() {
  try {
    File(_resultPath).writeAsStringSync(jsonEncode(_results));
  } on Object {
    // 非 Linux 本地开发没有 /tmp；UI 层读不到时会自动回落到脚本数据。
  }
}

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
  final bool ready = env['E2E_LIVE'] == '1' &&
      xfAppId.isNotEmpty &&
      xfKey.isNotEmpty &&
      xfSecret.isNotEmpty &&
      niuAppId.isNotEmpty &&
      niuKey.isNotEmpty;

  if (!ready) {
    test('E2E 真实三环（本轮不跑：E2E_LIVE 未开或凭证不全）', () {
      expect(ready, isFalse);
    });
    return;
  }

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

  test('E2E 真实链路：中文语音 → 维文译文 → 维语朗读', () async {
    // 阶段日志：真实链路上任何一环挂住都要能立刻看出卡在哪，
    // 否则只会得到一句「Test timed out after 5 minutes」。
    // ignore: avoid_print
    print('E2E live check: 中文方向 1/3 合成测试音…');
    // 用 TTS 造一段真实语音当「录音」，避免依赖 CI runner 上的物理麦克风。
    final XfyunSpeechPort source =
        XfyunSpeechPort(config: speechConfig, ttsMp3: false);
    final Uint8List pcm = await source.speak('你好', Language.chinese);
    expect(pcm.length, greaterThan(1000),
        reason: '合成的 PCM 太短，无法充当录音输入');
    // ignore: avoid_print
    print('E2E live check: 中文方向 2/3 测试音 ${pcm.length} 字节，开始三环…');

    // 刻意用 App 的默认端口与默认翻译链，覆盖设置页保存后的真实路径。
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: const ConfigurableSpeechPort(),
      translator: buildDefaultTranslator(),
    );
    final SpeechTurn turn =
        await pipeline.run(pcm, TranslationDirection.zhToUg);
    // ignore: avoid_print
    print('E2E live check: 中文方向 3/3 三环完成');

    expect(turn.heard.contains('你好'), isTrue,
        reason: 'ASR 没识别出合成的中文语音');
    expect(turn.translation.found, isTrue,
        reason: '小牛未返回译文：${translationConfig.lastDiagnostic}');
    expect(turn.translation.isDemo, isFalse,
        reason: '落到了演示词库，说明云端翻译没生效');
    expect(turn.translation.text.trim(), isNotEmpty);
    expect(turn.hasAudio, isTrue, reason: '译文没有生成朗读音频');

    _results['zh_heard'] = turn.heard;
    _results['zh_translated'] = turn.translation.text;
    _flushResults();
    // CI 靠这一行写 ::notice:: 批注，故显式豁免 avoid_print；不输出任何凭证。
    // ignore: avoid_print
    print('E2E live check: 中文识别=${turn.heard} '
        '译文=${turn.translation.text} provider=${turn.translation.provider} '
        '录音=${pcm.length}字节 朗读=${turn.audio.length}字节');
  });

  if (ugVcn.trim().isNotEmpty) {
    test('E2E 真实链路：维语语音 → 中文译文 → 中文朗读', () async {
      // ignore: avoid_print
      print('E2E live check: 维语方向 1/3 合成测试音…');
      final XfyunSpeechPort source =
          XfyunSpeechPort(config: speechConfig, ttsMp3: false);
      final Uint8List pcm = await source.speak(
        'ياخشىمۇسىز',
        Language.uyghur,
      );
      expect(pcm.length, greaterThan(1000));
      // ignore: avoid_print
      print('E2E live check: 维语方向 2/3 测试音 ${pcm.length} 字节，开始三环…');

      final SpeechPipeline pipeline = SpeechPipeline(
        speech: const ConfigurableSpeechPort(),
        translator: buildDefaultTranslator(),
      );
      final SpeechTurn turn =
          await pipeline.run(pcm, TranslationDirection.ugToZh);
      // ignore: avoid_print
      print('E2E live check: 维语方向 3/3 三环完成');

      expect(turn.heard.trim(), isNotEmpty);
      expect(turn.translation.found, isTrue,
          reason: '小牛未返回中文译文：${translationConfig.lastDiagnostic}');
      expect(turn.translation.isDemo, isFalse);
      expect(turn.translation.text.trim(), isNotEmpty);
      expect(turn.hasAudio, isTrue);

      _results['ug_heard'] = turn.heard;
      _results['ug_translated'] = turn.translation.text;
      _flushResults();
      // ignore: avoid_print
      print('E2E live check: 维语识别=${turn.heard} '
          '译文=${turn.translation.text} provider=${turn.translation.provider} '
          '录音=${pcm.length}字节 朗读=${turn.audio.length}字节');
    });
  }
}
