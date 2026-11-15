// 远程配置同步的唯一入口：ChangeNotifier 单例。
//
// 与 `UpdateNotifier` 并列但**刻意分开**：整包更新是「有新包 + 横幅 + 用户
// 去装」，配置同步是「静默、即时生效、无横幅」；塞进同一个 `available`
// 会互相干扰，也会共用同一个日节流时间戳。两者共用 `UpdateGateway` 与
// `UpdateStore.readBaseUrl()`，既隔离又复用。
//
// 触发点有两个，都在 `main()` 的启动页回调 / 设置页按钮里，widget 测试 pump
// `const BaseApp()` 不进 splash、不碰网络与文件系统（见 update_notifier.dart:10）。

import 'package:flutter/foundation.dart';

import 'remote_config.dart';
import 'remote_config_service.dart';
import 'remote_config_state.dart';
import 'remote_config_store.dart';
import 'update_store.dart';

class RemoteConfigNotifier extends ChangeNotifier {
  RemoteConfigNotifier._();

  static final RemoteConfigNotifier instance = RemoteConfigNotifier._();

  RemoteConfig _current = RemoteConfig.empty;
  RemoteConfigSource _source = RemoteConfigSource.empty;
  DateTime? _lastSync;
  String _error = '';
  bool _syncing = false;

  /// 测试注入的取数服务：widget 测试里替换成假网关，避免触碰真实网络。
  /// 生产恒为 null，走默认 `RemoteConfigService`。仿 `UpdateDialog(service:)`。
  @visibleForTesting
  RemoteConfigService? debugService;

  /// 生效中的配置（安全视图，不含密钥）。
  RemoteConfig get current => _current;

  RemoteConfigSource get source => _source;

  /// 配置版本，界面显示用。
  int get configVersion => _current.configVersion;

  DateTime? get lastSync => _lastSync;

  /// 上次失败原因（成功为空）。
  String get error => _error;

  bool get syncing => _syncing;

  /// 冷启动静默同步：默认一天最多一次，失败不弹任何东西。
  /// [force] 供设置页「立即同步配置」使用——用户主动点的必须真的去查。
  Future<RemoteConfigFetch?> checkInBackground({
    RemoteConfigService? service,
    RemoteConfigStore? store,
    bool force = false,
  }) async {
    final RemoteConfigStore cache = store ?? RemoteConfigStore();
    final String base = UpdateStore.readBaseUrl();
    if (base.trim().isEmpty) {
      // 没配更新源就什么都不做：这不是错误，只是没启用。
      return null;
    }
    if (!force) {
      final DateTime? last = cache.readLastSync();
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 24)) {
        return null;
      }
    }
    return _run(base, service: service, store: cache);
  }

  /// 手动同步：绕过日节流，返回结果供界面显示一行状态。
  Future<RemoteConfigFetch> sync({
    RemoteConfigService? service,
    RemoteConfigStore? store,
  }) async {
    final RemoteConfigStore cache = store ?? RemoteConfigStore();
    final String base = UpdateStore.readBaseUrl();
    if (base.trim().isEmpty) {
      // 没配地址也返回 empty 结果，让界面能显示「先填更新源地址」。
      return const RemoteConfigFetch(
        config: RemoteConfig.empty,
        source: RemoteConfigSource.empty,
        error: '还没有配置更新源地址',
      );
    }
    return _run(base, service: service, store: cache);
  }

  Future<RemoteConfigFetch> _run(
    String base, {
    RemoteConfigService? service,
    required RemoteConfigStore store,
  }) async {
    _syncing = true;
    notifyListeners();

    final RemoteConfigFetch result = await (service ??
            debugService ??
            RemoteConfigService(store: store))
        .fetch(base);

    // 构建应用选项：信任开关来自落盘值；host 白名单 = 更新源的 host。
    final RemoteConfigApplyOptions options = _buildOptions(base, store);
    applyRemoteConfig(result.config, options: options);

    _current = result.config;
    _source = result.source;
    _error = result.error ?? '';
    _lastSync = DateTime.now();
    store.writeLastSync(_lastSync!);
    _syncing = false;
    notifyListeners();
    return result;
  }

  RemoteConfigApplyOptions _buildOptions(
    String base,
    RemoteConfigStore store,
  ) {
    final Set<String> hosts = <String>{};
    try {
      final String host = Uri.parse(base.trim()).host.toLowerCase();
      if (host.isNotEmpty) {
        hosts.add(host);
      }
    } on Object {
      // base 已在 fetch 里校验过；这里解析失败就留空，URL 校验会更严格。
    }
    return RemoteConfigApplyOptions(
      trustSensitive: store.readTrustSensitive(),
      // 密钥永不下发：即便打开信任开关，也不开 trustSecrets，
      // 与「内置凭证包不被覆盖」双保险。要开启需另行增强。
      trustSecrets: false,
      allowedHosts: hosts,
    );
  }

  /// 测试用：清掉状态，避免用例之间互相影响。
  @visibleForTesting
  void reset() {
    _current = RemoteConfig.empty;
    _source = RemoteConfigSource.empty;
    _lastSync = null;
    _error = '';
    _syncing = false;
    debugService = null;
    remoteConfigState.reset();
    notifyListeners();
  }
}
