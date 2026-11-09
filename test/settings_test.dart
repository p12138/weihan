import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/main.dart';
import 'package:uyghur_interpreter/translation_config.dart';

void main() {
  setUp(() => translationConfig.reset());
  tearDown(() => translationConfig.reset());

  testWidgets('设置页可填入小牛 APPID 与 API-KEY，模式条切换为云端翻译',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    expect(find.textContaining('演示词库'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('云端翻译设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('provider-field')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('niutrans-appid-field')),
      'unit-test-appid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('translator-key-field')),
      'unit-test-key',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('云端翻译'), findsWidgets);
    expect(translationConfig.hasCloudKey, isTrue);
    expect(translationConfig.hasCloudConfig, isTrue);
    expect(translationConfig.provider, TranslationProvider.niuTrans);
  });

  testWidgets('清空 API-KEY 后回落到演示词库', (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('translator-key-field')),
      '',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('演示词库'), findsWidgets);
    expect(translationConfig.hasCloudKey, isFalse);
    expect(translationConfig.hasCloudConfig, isFalse);
  });
}
