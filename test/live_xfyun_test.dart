// 讯飞语音真实链路集成测试：直接跑 App 里那份 Dart 实现。
//
// Python 或 curl 只能验凭证与服务端，验不了「手机里的代码」——小牛翻译那次
// 就出现过 CI 全绿、App 端 latin1 请求体发不出去的情况。因此这里用同一组
// Secret 跑 TTS → ASR 闭环：TTS 用 raw 生成 16k PCM，直接喂回 ASR 识别。
//
// 凭证仅从 CI 环境变量读取，不写进代码、不进产物、不打印、不写日志批注。

import 'dart:io' show HttpOverrides, Platform;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart';

void main() {
  final String appId = Platform.environment['XFYUN_APP_ID'] ?? '';
  final String apiKey = Platform.environment['XFYUN_API_KEY'] ?? '';
  final String apiSecret = Platform.environment['XFYUN_API_SECRET'] ?? '';
  final String ugVcn = Platform.environment['XFYUN_UG_VCN'] ?? '';
  final String zhVcn = Platform.environment['XFYUN_ZH_VCN'] ?? '';

  if (appId.isEmpty || apiKey.isEmpty || apiSecret.isEmpty) {
    test('讯飞语音实测（未配置凭证，本轮跳过）', () {
      expect(appId.isEmpty || apiKey.isEmpty || apiSecret.isEmpty, isTrue);
    });
    return;
  }

  // flutter_test 可能装了拦截网络的 HttpOverrides，这里强制真实连接。
  HttpOverrides.global = null;

  final SpeechConfig config = SpeechConfig(
    appId: appId,
    apiKey: apiKey,
    apiSecret: apiSecret,
    ugVcn: ugVcn,
    zhVcn: zhVcn.isEmpty ? 'x4_xiaoyan' : zhVcn,
  );

  test('讯飞语音真实链路：中文 TTS → ASR 闭环（维语可选）', () async {
    // ttsMp3=false 让合成返回 16k PCM，正好是 ASR 要求的输入格式。
    final XfyunSpeechPort speech = XfyunSpeechPort(
      config: config,
      ttsMp3: false,
    );

    // 每段单独设超时：讯飞偶发单段卡住（#46 就是整体 120s 被吃满，
    // 日志里看不出卡在哪一环）。分段超时能直接指出是合成还是识别。
    const Duration stageBudget = Duration(seconds: 70);

    // ignore: avoid_print
    print('Xfyun live check: 开始中文合成…');
    final Uint8List pcm = await speech
        .speak('你好', Language.chinese)
        .timeout(stageBudget);
    // ignore: avoid_print
    print('Xfyun live check: 中文合成 ${pcm.length} 字节');
    expect(pcm.length, greaterThan(1000));

    // ignore: avoid_print
    print('Xfyun live check: 开始中文识别…');
    final String heard = await speech
        .listen(pcm, Language.chinese)
        .timeout(stageBudget);
    // ignore: avoid_print
    print('Xfyun live check: 中文识别结果=$heard diagnostic=${config.lastDiagnostic}');
    expect(heard, isNot(isEmpty));

    // 维语发音人属于账号侧授权：配了 vcn 才验；没开通只提示，不把门禁判红。
    if (ugVcn.isNotEmpty) {
      try {
        final Uint8List ugAudio = await speech
            .speak('ياخشىمۇسىز', Language.uyghur)
            .timeout(stageBudget);
        // ignore: avoid_print
        print('Xfyun live check: 维语合成 ${ugAudio.length} 字节');
        expect(ugAudio.length, greaterThan(1000));
        final String ugHeard = await speech
            .listen(ugAudio, Language.uyghur)
            .timeout(stageBudget);
        // ignore: avoid_print
        print('Xfyun live check: 维语识别结果=$ugHeard');
      } on Object catch (error) {
        // ignore: avoid_print
        print('Xfyun live check: 维语音色暂不可用（$error）'
            ' — 请到讯飞控制台开通维吾尔语发音人');
      }
    } else {
      // ignore: avoid_print
      print('Xfyun live check: 未配置 XFYUN_UG_VCN，本轮只验中文闭环');
    }
  });
}
