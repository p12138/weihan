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
import 'update_sources.dart';

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
    this.winningSource,
    this.configUri,
    this.attempts = const <SourceAttempt>[],
  });

  /// 生效用的配置（永不为 null；最差是 [RemoteConfig.empty]）。
  final RemoteConfig config;

  final RemoteConfigSource source;

  /// 失败原因（可读），仅当 [source] 不是 [RemoteConfigSource.fresh] 时有值。
  /// 网络成功时为空。
  final String? error;

  /// 多源回退时胜出的源（GitHub / NAS）；单源旧调用为 null。
  final UpdateSource? winningSource;

  /// 实际取到配置的地址，供状态行显示 / 测试核对。
  final Uri? configUri;

  /// 走到胜出或全失败前的失败尝试。
  final List<SourceAttempt> attempts;

  bool get isFresh => source == RemoteConfigSource.fresh;
}

class RemoteConfigService {
  const RemoteConfigService({
    this.gateway = const DartIoUpdateGateway(),
    this.store,
    this.sources,
  });

  final UpdateGateway gateway;
  final RemoteConfigStore? store;

  /// 显式注入的有序源（单测用）。生产为 null → [UpdateSources.instance]。
  final UpdateSources? sources;

  RemoteConfigStore get _store => store ?? RemoteConfigStore();

  UpdateSources get effectiveSources => sources ?? UpdateSources.instance;

  /// 配置文件固定为更新源同目录下的 `remote-config.json`。
  /// 与 `latest-android.json` 同目录；`deploy/nas/nginx.conf` 给它们同一条
  /// `no-store` 规则。基地址若显式指向某个 `.json`，则取它同目录的配置文件。
  Uri configUri(String baseUrl) {
    final Uri base = parseUpdateBase(baseUrl);
    return base.replace(path: '${updateDirectoryOf(base)}remote-config.json');
  }

  /// 取一次配置。[singleBase] 不为 null 时只查这一个地址（旧调用 / 单测）；
  /// 不传（生产）则走内置有序源：GitHub 主源优先，走不通回退 NAS。
  /// 任何失败都收敛成 [RemoteConfigFetch]，绝不抛到 UI。
  Future<RemoteConfigFetch> fetch([String? singleBase]) async {
    final RemoteConfigStore cache = _store;
    final List<UpdateSource> sourceList = singleBase != null
        ? <UpdateSource>[UpdateSource.single(singleBase)]
        : effectiveSources.ordered();

    final SourceFetch<RemoteConfig> fetched =
        await resolveFromSources<RemoteConfig>(
      sources: sourceList,
      uriOf: (UpdateSource s) => configUri(s.manifestBase),
      getText: gateway.getText,
      parse: RemoteConfig.parse,
    );

    if (fetched.ok) {
      final RemoteConfig config = fetched.value!;
      // 缓存不含密钥（`toCacheJson` 会去掉 secrets）。
      cache.writeCache(config.toCacheJson());
      return RemoteConfigFetch(
        config: config,
        source: RemoteConfigSource.fresh,
        winningSource: fetched.source,
        configUri: fetched.uri,
        attempts: fetched.attempts,
      );
    }

    // 全源失败：沿用上次好缓存；缓存也坏 → 回退空配置（全字段沿用）。
    final String reason = fetched.error ?? '配置同步失败';
    final String? cached = cache.readCache();
    if (cached != null) {
      try {
        final RemoteConfig config = RemoteConfig.parse(cached);
        return RemoteConfigFetch(
          config: config,
          source: RemoteConfigSource.cache,
          error: reason,
          attempts: fetched.attempts,
        );
      } on Object {
        cache.clearCache();
      }
    }
    return RemoteConfigFetch(
      config: RemoteConfig.empty,
      source: RemoteConfigSource.empty,
      error: reason,
      attempts: fetched.attempts,
    );
  }
}
