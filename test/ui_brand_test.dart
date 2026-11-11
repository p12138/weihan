// 视觉改版的回归锚点：标语、品牌标识、方向控件、语音按钮。
//
// 这些是「一改布局就容易被删掉」的东西：标语只出现在空状态，品牌标识只出现在
// 顶栏与空状态，语音按钮必须全页唯一（E2E 靠 Key('voice-button') 定位）。
// 用断言钉住，以后调样式时 CI 会拦住误删。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/brand_mark.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/main.dart';

void main() {
  testWidgets('空状态展示品牌标语与标识', (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());

    expect(find.text('融合'), findsOneWidget);
    expect(find.text('让沟通不再有障碍'), findsOneWidget);
    expect(find.text('让您和您的民族朋友沟通不再有障碍'), findsOneWidget);
    expect(find.byType(BrandMark), findsWidgets);
    // 三条操作提示都要在，别只留标语变成空荡荡一屏
    expect(find.text('按住按钮说话'), findsOneWidget);
    expect(find.text('译文会自动朗读'), findsOneWidget);
    expect(find.text('也可以直接打字'), findsOneWidget);
  });

  testWidgets('方向控件并列展示两种语言，点胶囊即可切换',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());

    expect(find.text(Language.chinese.label), findsOneWidget);
    expect(find.text(Language.uyghur.label), findsOneWidget);
    expect(find.textContaining('中文 → ئۇيغۇرچە'), findsOneWidget);

    // 点维语胶囊 = 把维语设为「我说的话」
    await tester.tap(find.text(Language.uyghur.label));
    await tester.pumpAndSettle();
    expect(find.textContaining('ئۇيغۇرچە → 中文'), findsOneWidget);
  });

  testWidgets('语音未配置时按钮禁用，按住只给出提示',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());

    final Finder voice = find.byKey(const ValueKey<String>('voice-button'));
    expect(voice, findsOneWidget);
    expect(find.text('按住说话 · 待接入'), findsOneWidget);

    final TestGesture hold = await tester.startGesture(tester.getCenter(voice));
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('语音未接入'), findsOneWidget);
  });
}
