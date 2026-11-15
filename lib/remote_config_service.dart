// 远程配置的取数：取文本 → 解析 → 写缓存 → 返回结果。
//
// 与 `UpdateService` 同源：复用 `UpdateGateway` / `DartIoUpdateGateway`（8s/20s
// 超时、`Cache-Control: no-cache`）、`parseUpdateBase` 的地址校验、
// `describeUpdateError` 的可读错误。区别只在「取什么文件、怎么解析」。
//
// 一条硬规则：**任何失败都不抛到 UI**。成功 → 用新配置；失败 → 回退上次好
// 缓存；缓存也坏 → 回退 `RemoteConfig.empty()`（全字段沿用）。出门没网、
// NAS 重启、JSON 写错都不该让 App 起不来或弹一堆红字。

import 'remote_config.dart';
import 'remote_config_store.dart';
import 'update_service.dart';

/// 这次拿到配置来自哪里，供界面显示「实时 / 缓存 / 未启用」。
enum RemoteConfigSource {
  /// 网络取回并解析成功。
  fresh,

  /// 网络失败，用了上次成功缓存。
  cache,

  /// 网络失败且无缓存，全字段沿用内置默认。
  empty,
}

class RemoteConfigFetch {
  const RemoteConfigFetch({
    required this.config,
    required this.source,
    this.error,
  });

  /// 生效用的配置（永不为 null；最差是 [RemoteConfig.empty]）。
  final RemoteConfig config;

  final RemoteConfigSource source;

  /// 失败原因（可读），仅当 [source] 不是 [RemoteConfigSource.fresh] 时有值。
  /// 网络成功时为空。
  final String? error;

  bool get isFresh => source == RemoteConfigSource.fresh;
}

class RemoteConfigService {
  const RemoteConfigService({
    this.gateway = const DartIoUpdateGateway(),
    this.store,
  });

  final UpdateGateway gateway;
  final RemoteConfigStore? store;

  RemoteConfigStore get _store => store ?? RemoteConfigStore();

  /// 配置文件固定为更新源同目录下的 `remote-config.json`。
  /// 与 `latest-android.json` 同目录；`deploy/nas/nginx.conf` 给它们同一条
  /// `no-store` 规则。基地址若显式指向某个 `.json`，则取它同目录的配置文件。
  Uri configUri(String baseUrl) {
    final Uri base = parseUpdateBase(baseUrl);
    final String path = base.path;
    final int slash = path.lastIndexOf('/');
    final String dir = path.endsWith('.json')
        ? (slash >= 0 ? path.substring(0, slash + 1) : '/')
        : (path.endsWith('/') ? path : '$path/');
    return base.replace(path: '${dir}remote-config.json');
  }

  /// 取一次配置。异常一律收敛成 [RemoteConfigFetch]，绝不抛出。
  Future<RemoteConfigFetch> fetch(String baseUrl) async {
    final RemoteConfigStore cache = _store;
    try {
      final Uri uri = configUri(baseUrl);
      final String body = await gateway.getText(uri);
      final RemoteConfig config = RemoteConfig.parse(body);
      // 缓存不含密钥（`toCacheJson` 会去掉 secrets）。
      cache.writeCache(config.toCacheJson());
      return RemoteConfigFetch(
        config: config,
        source: RemoteConfigSource.fresh,
      );
    } on Object catch (error) {
      final String reason = describeUpdateError(error);
      final String? cached = cache.readCache();
      if (cached != null) {
        try {
          final RemoteConfig config = RemoteConfig.parse(cached);
          return RemoteConfigFetch(
            config: config,
            source: RemoteConfigSource.cache,
            error: reason,
          );
        } on Object {
          // 缓存损坏：删掉，避免每次冷启动都重复报同一个错。
          cache.clearCache();
        }
      }
      return RemoteConfigFetch(
        config: RemoteConfig.empty,
        source: RemoteConfigSource.empty,
        error: reason,
      );
    }
  }
}
