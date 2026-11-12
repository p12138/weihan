// 启动页的回归锚点。
//
// 真机反馈过两件事：①「一闪就过，看不清写的什么」→ Flutter 侧接一屏同款视觉
// 停够时间；②「冷启动先出现小一号的启动页」→ 原生层不再放整页缩略位图，
// Flutter 这一屏从第一帧就全屏、且不做任何缩放。用短 hold 把状态钉住，
// 避免以后又被优化掉。

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
    expect(find.text('让您和民族朋友的'), findsOneWidget);
    expect(find.textContaining('不再有障碍'), findsOneWidget,
        reason: '两行连起来是「让您和民族朋友的沟通不再有障碍」');
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

  testWidgets('启动页从第一帧就全屏铺底，不用缩放动画',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp(
      showSplash: true,
      splashHold: Duration(milliseconds: 900),
    ));

    // 任何 ScaleTransition / Transform.scale 都会让冷启动看起来像
    // 「先有一个小页面再放大」，这里直接钉死：只允许纯透明度淡入。
    expect(
      find.descendant(
        of: find.byKey(_splashKey),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(_splashKey),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(_splashKey),
        matching: find.byType(Opacity),
      ),
      findsWidgets,
    );

    final Size splash = tester.getSize(find.byKey(_splashKey));
    expect(splash.width, greaterThan(300));
    expect(splash.height, greaterThan(300));

    // 让 hold 的 Timer 正常触发，测试结束不留悬挂定时器。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
  });

  testWidgets('测试默认不套启动页，首屏直接是对话页',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());
    expect(find.byKey(_splashKey), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
