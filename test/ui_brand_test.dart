// 视觉改版的回归锚点：标语、品牌标识、唯一语音按钮。
//
// 这些是「一改布局就容易被删掉」的东西：标语只出现在空状态，品牌标识只出现在
// 顶栏与空状态，语音按钮必须全页唯一（既有 E2E 靠它判定语音入口）。用断言钉住，
// 以后调样式时 CI 会拦住误删。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/brand_mark.dart';
import 'package:uyghur_interpreter/main.dart';

void main() {
  testWidgets('空状态展示品牌标语与标识', (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());

    expect(find.text('融合'), findsOneWidget);
    expect(find.text('让沟通不再有障碍'), findsOneWidget);
    expect(find.text('让您和您的民族朋友沟通不再有障碍'), findsOneWidget);
    expect(find.byType(BrandMark), findsWidgets);
    // 三条操作提示都要在，别只留标语变成空荡荡一屏
    expect(find.text('点一下麦克风说话'), findsOneWidget);
    expect(find.text('译文会自动朗读'), findsOneWidget);
    expect(find.text('也可以直接打字'), findsOneWidget);
  });

  testWidgets('语音未配置时，全页只有一个禁用状态的语音按钮',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());

    final Finder voiceButton = find.byWidgetPredicate(
      (Widget widget) => widget is TextButton,
    );
    expect(voiceButton, findsOneWidget);
    expect(tester.widget<TextButton>(voiceButton).onPressed, isNull);
    expect(find.text('按住说话 · 待接入'), findsOneWidget);
  });
}
