import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/main.dart';

void main() {
  testWidgets('首页渲染标题、方向条与演示模式提示', (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    expect(find.text('融合'), findsOneWidget);
    expect(find.textContaining('演示词库'), findsOneWidget);
    expect(find.textContaining('语音待接入'), findsOneWidget);
  });
}
