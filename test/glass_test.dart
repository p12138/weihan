// 玻璃层的行为契约：不同系统拿到不同"厚薄"，且面板不会崩。
//
// 真机上很难断言模糊效果（截图比对成本高），这里只钉住「选型」这一层：
// 非 iOS 不吐 iOS 版本号、默认走磨砂、覆盖后按覆盖值渲染。视觉回归交给截图。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/glass.dart';

void main() {
  tearDown(() => Glass.override = null);

  test('非 iOS 环境不返回 iOS 主版本号', () {
    // 测试跑在 Linux / macOS 的 dart 虚拟机上，不是 iOS
    expect(Glass.iOsMajorVersion, isNull);
  });

  test('默认走磨砂玻璃，模糊半径大于 0', () {
    Glass.override = null;
    final GlassSpec spec = Glass.spec;
    expect(spec.kind, GlassKind.frosted);
    expect(spec.blur, greaterThan(0));
    expect(spec.fillOpacity, inInclusiveRange(0.5, 0.95));
  });

  test('可覆盖为液态玻璃，高光开关随之变化', () {
    Glass.override = GlassSpec.liquidIOS;
    expect(Glass.spec.kind, GlassKind.liquid);
    expect(Glass.spec.specular, isTrue);
    expect(Glass.spec.label, contains('26'));
  });

  test('旧系统退回实色：不模糊、不透明', () {
    Glass.override = GlassSpec.solidSystem;
    expect(Glass.spec.kind, GlassKind.solid);
    expect(Glass.spec.blur, 0);
    expect(Glass.spec.fillOpacity, greaterThan(0.9));
  });

  testWidgets('GlassPanel 正常渲染子节点', (WidgetTester tester) async {
    Glass.override = GlassSpec.liquidIOS;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassPanel(
              padding: EdgeInsets.all(16),
              child: Text('玻璃面板'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('玻璃面板'), findsOneWidget);
    expect(find.byType(GlassPanel), findsOneWidget);
  });
}
