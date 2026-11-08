import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/main.dart';

void main() {
  testWidgets('地基页渲染中文说明与维文 RTL 样例', (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    expect(find.textContaining('工具链地基'), findsOneWidget);
    expect(find.textContaining('ئۇيغۇرچە'), findsOneWidget);
  });
}
