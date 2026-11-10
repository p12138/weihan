// 自带凭证自用包的设置页回归。
//
// 普通 CI（不带 --dart-define）走「未内置」分支，验证不会平白多出提示；
// selfuse-bundled.yml 会用 --dart-define-from-file 再单独跑一次本文件，
// 验证凭证确实注入、设置页不回显密钥、直接点保存也不会把内置值清空。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/bundled_config.dart';
import 'package:uyghur_interpreter/main.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/translation_config.dart';

void main() {
  setUp(() {
    translationConfig.reset();
    speechConfig.reset();
  });
  tearDown(() {
    translationConfig.reset();
    speechConfig.reset();
  });

  testWidgets('内置凭证包：提示已内置 / 密钥不回显 / 直接保存不清空',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    if (!kHasBundledCredentials) {
      expect(
        find.byKey(const ValueKey<String>('bundled-config-notice')),
        findsNothing,
      );
      return;
    }

    expect(
      find.byKey(const ValueKey<String>('bundled-config-notice')),
      findsOneWidget,
    );
    expect(find.text(kBundledCredentialsNotice), findsOneWidget);
    expect(speechConfig.hasConfig, isTrue);
    expect(translationConfig.hasCloudConfig, isTrue);

    // 只检查输入框里的文本，绝不把凭证值写进日志或断言消息。
    for (final String fieldKey in <String>[
      'niutrans-appid-field',
      'translator-key-field',
      'xfyun-appid-field',
      'xfyun-apikey-field',
      'xfyun-apisecret-field',
    ]) {
      final TextField field = tester.widget<TextField>(
        find.byKey(ValueKey<String>(fieldKey)),
      );
      expect(
        field.controller?.text.trim(),
        isEmpty,
        reason: '$fieldKey 不应回显内置凭证',
      );
    }

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(speechConfig.hasConfig, isTrue);
    expect(translationConfig.hasCloudConfig, isTrue);
    expect(speechConfig.canSpeak(false), isTrue);
  });
}
