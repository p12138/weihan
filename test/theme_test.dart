// 主题配色系统的契约：色板齐全、切换只影响全局色板、设置页能真的换色。
//
// 这里钉住三件容易在后续改动里被破坏的事：
//   1. 每套配色都是完整的（缺色会让界面某处退回透明或黑）；
//   2. 「中文=主色、维文=强调色」的绑定关系不变；
//   3. 切换后 MaterialApp 的 ColorScheme 真的跟着变（否则只是变量变了、界面没变）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/main.dart';
import 'package:uyghur_interpreter/palette_controller.dart';
import 'package:uyghur_interpreter/theme.dart';

void main() {
  tearDown(() => PaletteController.instance.reset());

  test('四套配色各不相同，B 站用的是官方粉与官方蓝', () {
    expect(BrandPalette.all.length, greaterThanOrEqualTo(4));
    final Set<String> ids =
        BrandPalette.all.map((BrandPalette p) => p.id).toSet();
    expect(ids.length, BrandPalette.all.length, reason: 'id 必须唯一，否则持久化会串');

    expect(BrandPalette.bilibili.primary, const Color(0xFFFB7299));
    expect(BrandPalette.bilibili.accent, const Color(0xFF00A1D6));
    // 深浅阶要能拉开，否则头图渐变会糊成一块
    for (final BrandPalette palette in BrandPalette.all) {
      expect(palette.primaryLight, isNot(palette.primaryDeep));
      expect(palette.primarySoft, isNot(palette.accentSoft));
      expect(palette.swatch.length, 2);
    }
  });

  test('未知 id 回落到默认主题，不会抛异常', () {
    expect(BrandPalette.byId('nope').id, 'adeles');
    expect(BrandPalette.byId(null).id, 'adeles');
    expect(BrandPalette.byId('bilibili').id, 'bilibili');
  });

  test('每套配色都能建出主题，主色与底色进入 ColorScheme', () {
    for (final BrandPalette palette in BrandPalette.all) {
      AppColors.palette = palette;
      final ThemeData theme = AppTheme.light();
      expect(theme.colorScheme.primary, palette.primary);
      expect(theme.colorScheme.secondary, palette.accent);
      expect(theme.scaffoldBackgroundColor, palette.canvas);
    }
  });

  test('切换主题后全局色板立即变化，语言色跟着走', () {
    PaletteController.instance.select(BrandPalette.bilibili);
    expect(AppColors.primary, BrandPalette.bilibili.primary);
    expect(AppColors.language(false), BrandPalette.bilibili.primary);
    expect(AppColors.language(true), BrandPalette.bilibili.accent);

    PaletteController.instance.select(BrandPalette.pomegranate);
    expect(AppColors.primary, BrandPalette.pomegranate.primary);
    expect(AppColors.sand, BrandPalette.pomegranate.accent);
  });

  testWidgets('设置页能切到 B 站配色，主题立即重建',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BaseApp());

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('主题配色'), findsOneWidget);

    await tester.tap(find.text('B 站'));
    await tester.pumpAndSettle();

    expect(AppColors.palette.id, 'bilibili');
    final BuildContext context = tester.element(find.text('主题配色'));
    expect(Theme.of(context).colorScheme.primary, BrandPalette.bilibili.primary);
  });
}
