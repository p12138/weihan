// 真实网络集成测试：验证 App 里 Dart 实现的完整请求路径。
//
// 与 workflow 里的 Python live check 分工不同：
//   - Python 那条只回答「凭证 / 语种码 / 服务端是否可用」；
//   - 这一条回答「用户手机里跑的那份 Dart 代码能不能真的翻出来」。
// 此前只验了前者，出现过 CI 全绿但 App 端失败却无法定位的情况。
//
// 凭证仅从 CI 环境变量读取，不写进代码、不进产物、不打印、不写日志批注。

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/niutrans_translator.dart';
import 'package:uyghur_interpreter/translation_config.dart';

void main() {
  final String appId = Platform.environment['NIUTRANS_APP_ID'] ?? '';
  final String apiKey = Platform.environment['NIUTRANS_API_KEY'] ?? '';
  final String configuredCode =
      (Platform.environment['NIUTRANS_UG_CODE'] ?? '').trim();

  if (appId.isEmpty || apiKey.isEmpty) {
    // 本地开发 / 未配 Secret 的 fork 上不发起任何网络请求。
    test('Dart 云端实测（未配置凭证，本轮跳过）', () {
      expect(appId.isEmpty || apiKey.isEmpty, isTrue);
    });
    return;
  }

  test('Dart 实现真实调用小牛：你好 → 维语', () async {
    final TranslationConfig config = TranslationConfig(
      provider: TranslationProvider.niuTrans,
      appId: appId,
      key: apiKey,
      ugCode: configuredCode.isEmpty ? 'uy' : configuredCode,
    );
    final NiuTransTranslator translator = NiuTransTranslator(config: config);
    final Translation result = await translator.translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    // 只输出结论与诊断，绝不输出凭证。
    print('Dart live check: found=${result.found} '
        'provider=${result.provider} text=${result.text} '
        'diagnostic=${config.lastDiagnostic}');
    expect(
      result.found,
      isTrue,
      reason: 'Dart 实现未拿到译文：${config.lastDiagnostic}',
    );
    expect(result.text.trim(), isNotEmpty);
    expect(result.isDemo, isFalse);
  });
}
