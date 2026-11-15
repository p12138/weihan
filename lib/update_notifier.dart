import 'package:flutter/foundation.dart';

import 'app_version.dart';
import 'update_manifest.dart';
import 'update_service.dart';
import 'update_sources.dart';
import 'update_store.dart';

/// 后台静默检查的唯一入口。
///
/// 单独抽出来而不是塞进 `ConversationPage`，是为了让「启动时查一次」这件事
/// 只发生在真正的 `main()` 里：widget 测试构造页面时不会去碰网络与文件系统。
class UpdateNotifier extends ChangeNotifier {
  UpdateNotifier._();

  static final UpdateNotifier instance = UpdateNotifier._();

  UpdateManifest? _available;
  UpdateSource? _winningSource;
  Uri? _manifestUri;

  /// 查到的新版本；没有就是 null。界面据此决定要不要显示横幅。
  UpdateManifest? get available => _available;

  bool get hasUpdate => _available != null;

  /// 这次检查胜出的更新源（GitHub / NAS）。横幅进对话框时要带上，
  /// 保证下载 APK 用的是该源的载荷地址（设计 A：GitHub 胜出、载荷在 NAS）。
  UpdateSource? get winningSource => _winningSource;

  /// 胜出源实际取到的清单地址，传给 [UpdateDialog] 避免回退后仍去主源下载。
  Uri? get manifestUri => _manifestUri;

  /// 当前安装的版本，显示用。
  String get currentVersion => kAppVersion;

  /// 静默检查：默认一天最多一次，失败不弹任何东西。
  ///
  /// [force] 供设置页「检查更新」使用——用户主动点的就必须真的去查。
  /// 内置 GitHub 主源恒存在，不再有「没填地址就跳过」这一状态。
  Future<UpdateCheck?> checkInBackground({
    UpdateService? service,
    bool force = false,
  }) async {
    if (!force) {
      final DateTime? last = UpdateStore.readLastCheck();
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 24)) {
        return null;
      }
    }

    // 走内置有序源：GitHub 主源优先，连不上自动回退 NAS。
    final UpdateCheck result = await (service ?? UpdateService()).check();
    if (result.status == UpdateCheckStatus.failed) {
      // 全源失败不写节流时间戳：否则一次断网会压住 24h 不再重试。
      return result;
    }
    UpdateStore.writeLastCheck(DateTime.now());
    _winningSource = result.source;
    _manifestUri = result.manifestUri;
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
    _winningSource = null;
    _manifestUri = null;
  }
}
