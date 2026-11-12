import 'package:flutter/foundation.dart';

import 'app_version.dart';
import 'update_manifest.dart';
import 'update_service.dart';
import 'update_store.dart';

/// 后台静默检查的唯一入口。
///
/// 单独抽出来而不是塞进 `ConversationPage`，是为了让「启动时查一次」这件事
/// 只发生在真正的 `main()` 里：widget 测试构造页面时不会去碰网络与文件系统。
class UpdateNotifier extends ChangeNotifier {
  UpdateNotifier._();

  static final UpdateNotifier instance = UpdateNotifier._();

  UpdateManifest? _available;

  /// 查到的新版本；没有就是 null。界面据此决定要不要显示横幅。
  UpdateManifest? get available => _available;

  bool get hasUpdate => _available != null;

  /// 当前安装的版本，显示用。
  String get currentVersion => kAppVersion;

  /// 静默检查：默认一天最多一次，失败不弹任何东西。
  ///
  /// [force] 供设置页「检查更新」使用——用户主动点的就必须真的去查。
  Future<UpdateCheck?> checkInBackground({
    UpdateService? service,
    bool force = false,
  }) async {
    final String base = UpdateStore.readBaseUrl();
    if (base.trim().isEmpty) {
      // 没配更新源就什么都不做：这不是错误，只是没启用。
      return null;
    }
    if (!force) {
      final DateTime? last = UpdateStore.readLastCheck();
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 24)) {
        return null;
      }
    }
    UpdateStore.writeLastCheck(DateTime.now());

    final UpdateCheck result =
        await (service ?? UpdateService()).check(base);
    if (result.status == UpdateCheckStatus.available) {
      _available = result.manifest;
      notifyListeners();
    }
    return result;
  }

  /// 用户点了「以后再说」。
  void dismiss() {
    if (_available == null) {
      return;
    }
    _available = null;
    notifyListeners();
  }

  /// 测试用：清掉状态，避免用例之间互相影响。
  @visibleForTesting
  void reset() {
    _available = null;
  }
}
