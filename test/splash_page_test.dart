// 启动页停留时长的回归锚点。
//
// 真机反馈「启动页一闪就过，看不清写的什么」：原生启动图在 Flutter 首帧就被
// 系统撤掉，所以这里在 Flutter 侧接一屏同款视觉并停够时间。用短 hold 把
// 「停留期间 / 停留结束」两个状态都钉住，避免以后又被优化掉。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/main.dart';
import 'package:uyghur_interpreter/splash_page.dart';

const Key _splashKey = ValueKey<String>('splash-view');

void main() {
  test('默认停留不少于 2 秒，够读完两行标语', () {
    expect(kSplashHold.inMilliseconds, greaterThanOrEqualTo(2000));
  });

  testWidgets('启动页停满才淡出到对话页，文字期间清晰可见',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp(
      showSplash: true,
      splashHold: Duration(milliseconds: 900),
    ));

    expect(find.byKey(_splashKey), findsOneWidget);
    expect(find.text('融合'), findsOneWidget);
    expect(find.text('让您和您的民族朋友'), findsOneWidget);
    expect(find.text('BRIDGING EVERY CONVERSATION'), findsOneWidget);
    expect(find.text('语言无界 · 心意相通'), findsOneWidget);
    // 停留期间对话页还没建，用户不会误触到一个看不见的输入框。
    expect(find.byType(TextField), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_splashKey), findsOneWidget,
        reason: '0.4 秒时启动页必须还在，不能又是一闪而过');

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(_splashKey), findsNothing, reason: '到点后要收起');
    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('voice-button')),
      findsOneWidget,
    );
  });

  testWidgets('测试默认不套启动页，首屏直接是对话页',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    expect(find.byKey(_splashKey), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
