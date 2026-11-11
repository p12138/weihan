import 'package:flutter/foundation.dart';

import 'palette_store.dart';
import 'theme.dart';

/// 主题控制器：唯一的切换入口。
///
/// 切主题的顺序很重要 —— 先改 [AppColors.palette]，再 notifyListeners，
/// 这样重建时取到的一定是新色板，不会出现「一半旧色一半新色」的中间帧。
class PaletteController extends ChangeNotifier {
  PaletteController._();

  static final PaletteController instance = PaletteController._();

  /// 当前配色。
  BrandPalette get palette => AppColors.palette;

  /// 启动时读一次上次的选择。只在 `main()` 里调用，
  /// 测试里直接构造 `BaseApp` 就不会碰文件系统，断言始终从默认主题开始。
  void load() {
    AppColors.palette = BrandPalette.byId(PaletteStore.read());
  }

  /// 选择一套配色并记住它。
  void select(BrandPalette palette) {
    if (palette.id == AppColors.palette.id) {
      return;
    }
    AppColors.palette = palette;
    PaletteStore.write(palette.id);
    notifyListeners();
  }

  /// 回到默认配色，供测试清理。
  @visibleForTesting
  void reset() {
    AppColors.palette = BrandPalette.adeles;
    notifyListeners();
  }
}
