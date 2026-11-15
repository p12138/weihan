import 'update_store.dart';

/// 一个「更新源」：控制面地址（清单 / 配置 JSON）与载荷地址（APK / IPA）
/// 刻意分开。
///
/// 仓库是 public、自用包内含编译期凭证，所以含凭证的 APK 只能发草稿 Release，
/// 匿名客户端不可下载。于是 GitHub 只放**无密钥的控制面**（`latest-*.json` /
/// `remote-config.json`），真正的安装包恒在 NAS：GitHub 源的 [payloadBase]
/// 指向 NAS，NAS 源的 [payloadBase] 就是它自己。这样「内置 GitHub 主源 +
/// NAS 兜底」成立，凭证又不外泄。
class UpdateSource {
  const UpdateSource({
    required this.id,
    required this.manifestBase,
    required this.payloadBase,
    required this.label,
  });

  /// 旧调用 / 单元测试用：清单与载荷同一个地址，行为与重构前完全一致。
  factory UpdateSource.single(String base) => UpdateSource(
        id: 'single',
        manifestBase: base,
        payloadBase: base,
        label: '自定义',
      );

  /// `github` / `nas` / `override` / `single`。
  final String id;

  /// 控制面基址：`manifestUri()` / `configUri()` 从这里拼文件名。
  final String manifestBase;

  /// 载荷基址：`download()` / `downloadPage()` 从这里拼 `manifest.file`。
  final String payloadBase;

  /// 出错时显示给用户看的中文标签。
  final String label;

  @override
  String toString() => 'UpdateSource($id, $manifestBase → $payloadBase)';
}

/// 内置的有序更新源。用户不再手填地址：GitHub 是内置主源，NAS 是兜底。
///
/// 三个基址都可用 `--dart-define` 在编译期注入（由 `write_bundle_defines.py`
/// 与 `selfuse-bundled.yml` 提供）。未注入时也有硬编码的 GitHub 兜底，保证本地
/// `flutter test` / 无 dart-define 的构建仍有一个主源可查。
class UpdateSources {
  UpdateSources({
    String? githubBase,
    String? nasBase,
    String? githubPayloadBase,
    this.overrideBase,
  })  : githubBase = (githubBase ?? compiledGithubBase).trim(),
        nasBase = (nasBase ?? compiledNasBase).trim(),
        githubPayloadBase =
            (githubPayloadBase ?? compiledGithubPayloadBase).trim();

  static const String compiledGithubBase =
      String.fromEnvironment('UPDATE_GITHUB_BASE');
  static const String compiledNasBase =
      String.fromEnvironment('UPDATE_NAS_BASE');
  static const String compiledGithubPayloadBase =
      String.fromEnvironment('UPDATE_GITHUB_PAYLOAD_BASE');

  /// 没有 dart-define 时的内置主源（公开、无密钥的控制面目录）。
  static const String fallbackGithubBase =
      'https://raw.githubusercontent.com/p12138/weihan/main/deploy/update';

  static final UpdateSources instance = UpdateSources();

  final String githubBase;
  final String nasBase;
  final String githubPayloadBase;

  /// 显式覆盖（测试注入用）。为 null 时每次 [ordered] 现读
  /// [UpdateStore.readBaseUrl]，兼容老安装里手工填过的地址，也不缓存。
  final String? overrideBase;

  String _override() =>
      overrideBase != null ? overrideBase!.trim() : UpdateStore.readBaseUrl().trim();

  /// 有序源：可选 override → GitHub（主，恒存在）→ NAS（配了才加）。
  List<UpdateSource> ordered() {
    final String gh = githubBase.isNotEmpty ? githubBase : fallbackGithubBase;
    // 设计 A：GitHub 控制面的载荷恒指向 NAS（BUNDLE_ALLOW_PUBLIC=1 时
    // 才注入 githubPayloadBase 让 GitHub 变成完整源）。都没配就退回 gh。
    final String ghPayload = githubPayloadBase.isNotEmpty
        ? githubPayloadBase
        : (nasBase.isNotEmpty ? nasBase : gh);

    final List<UpdateSource> out = <UpdateSource>[];
    final String ov = _override();
    if (ov.isNotEmpty) {
      out.add(UpdateSource(
        id: 'override',
        manifestBase: ov,
        payloadBase: ov,
        label: '自定义',
      ));
    }
    out.add(UpdateSource(
      id: 'github',
      manifestBase: gh,
      payloadBase: ghPayload,
      label: 'GitHub',
    ));
    if (nasBase.isNotEmpty) {
      out.add(UpdateSource(
        id: 'nas',
        manifestBase: nasBase,
        payloadBase: nasBase,
        label: 'NAS',
      ));
    }
    return out;
  }

  /// 所有控制面源的 host（GitHub + NAS + override）。给远程配置的
  /// `allowedHosts` 用：源切换后端点不会因 host 不在白名单被误拒。
  Set<String> get sourceHosts => ordered()
      .map((UpdateSource s) => _host(s.manifestBase))
      .where((String h) => h.isNotEmpty)
      .toSet();

  /// 更严的端点白名单：只放行 override + NAS，不含 GitHub 控制面 host。
  /// 默认 [RemoteConfigNotifier] 用 [sourceHosts]；这是一行可切换的加固选项。
  Set<String> get endpointHosts {
    final Set<String> hosts = <String>{};
    final String ov = _host(_override());
    if (ov.isNotEmpty) {
      hosts.add(ov);
    }
    final String nas = _host(nasBase);
    if (nas.isNotEmpty) {
      hosts.add(nas);
    }
    return hosts;
  }

  String _host(String raw) {
    try {
      return Uri.parse(raw.trim()).host.toLowerCase();
    } on Object {
      return '';
    }
  }
}
