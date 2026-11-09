import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/main.dart';

// 把「真机上肉眼验证过」的行为固化成自动断言：
// 以后改代码时 CI 会替人回归，不需要再手动装包点一遍。
void main() {
  testWidgets('输入「你好」后给出维文译文，并标明是演示词库结果',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('ئەسسالامۇ ئەلەيكۇم'), findsOneWidget);
    expect(find.textContaining('演示词库命中'), findsOneWidget);
  });

  testWidgets('未收录的句子不伪造译文，给出明确提示',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    await tester.enterText(find.byType(TextField), '今天天气怎么样');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.textContaining('演示词库未收录这句'), findsOneWidget);
    expect(find.text('今天天气怎么样'), findsOneWidget);
  });

  testWidgets('切换方向后模式条同步变化，语音入口保持禁用',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    expect(find.textContaining('中文 → ئۇيغۇرچە'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();

    expect(find.textContaining('ئۇيغۇرچە → 中文'), findsOneWidget);
    // TextButton.icon 的 runtimeType 是私有的 _TextButtonWithIcon，
    // find.byType(TextButton) 精确匹配会查不到，这里改用类型谓词。
    final Finder voiceButton = find.byWidgetPredicate(
      (Widget widget) => widget is TextButton,
    );
    expect(voiceButton, findsOneWidget);
    expect(tester.widget<TextButton>(voiceButton).onPressed, isNull);
  });
}
