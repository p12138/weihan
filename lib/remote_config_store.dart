// 远程配置的落盘：缓存 + 上次同步时间 + 「信任敏感项」开关。
//
// 与 `UpdateStore` / `PaletteStore` 同样的取舍：不为此引入 shared_preferences
// 这种平台插件，只写纯文本小文件到系统临时目录。丢了也无所谓——回退到
// 「沿用内置默认」，下次同步再拿回来，绝不 brick App。
//
// 缓存写 `.tmp` 再 rename，避免半截 JSON 把下次冷启动带崩；缓存内容由
// `RemoteConfig.toCacheJson()` 生成，**不含任何密钥**（密钥只在进程内存）。
//
// 默认用 `Directory.systemTemp`；测试可注入独立 `Directory`，避免并行用例
// 抢同一个文件（与 `UpdateService(downloadDir:)` 同一个套路）。

import 'dart:io';

class RemoteConfigStore {
  RemoteConfigStore({Directory? directory}) : _directory = directory;

  static const String _cacheFileName = 'weihan_remote_config.json';
  static const String _lastSyncFileName = 'weihan_remote_config_last_sync.txt';
  static const String _trustFileName = 'weihan_remote_config_trust.txt';

  final Directory? _directory;

  Directory get _dir => _directory ?? Directory.systemTemp;

  File _file(String name) =>
      File('${_dir.path}${Platform.pathSeparator}$name');

  /// 最近一次成功取回的配置文本（不含密钥）。没有 / 损坏时返回 null。
  String? readCache() {
    try {
      final File file = _file(_cacheFileName);
      if (!file.existsSync()) {
        return null;
      }
      final String text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  /// 写入缓存：先写 `.tmp`，再原子 rename，避免半文件。
  bool writeCache(String text) {
    try {
      final File file = _file(_cacheFileName);
      final File tmp = _file('$_cacheFileName.tmp');
      tmp.writeAsStringSync(text);
      if (file.existsSync()) {
        file.deleteSync();
      }
      tmp.renameSync(file.path);
      return true;
    } on Object {
      _cleanTmp();
      return false;
    }
  }

  void clearCache() {
    try {
      final File file = _file(_cacheFileName);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object {
      // 删不掉也不影响：下次取回成功会覆盖。
    }
    _cleanTmp();
  }

  void _cleanTmp() {
    try {
      final File tmp = _file('$_cacheFileName.tmp');
      if (tmp.existsSync()) {
        tmp.deleteSync();
      }
    } on Object {
      // 忽略。
    }
  }

  /// 上次同步时间，用于冷启动日节流。
  DateTime? readLastSync() {
    try {
      final File file = _file(_lastSyncFileName);
      if (!file.existsSync()) {
        return null;
      }
      return DateTime.tryParse(file.readAsStringSync().trim());
    } on Object {
      return null;
    }
  }

  bool writeLastSync(DateTime at) {
    try {
      _file(_lastSyncFileName).writeAsStringSync(at.toIso8601String());
      return true;
    } on Object {
      return false;
    }
  }

  /// 「信任远程配置的服务商/端点/密钥覆盖」开关：默认关（零信任）。
  /// 只有用户主动打开，Tier B 敏感字段才可能被应用。
  bool readTrustSensitive() {
    try {
      final File file = _file(_trustFileName);
      if (!file.existsSync()) {
        return false;
      }
      return file.readAsStringSync().trim() == '1';
    } on Object {
      return false;
    }
  }

  bool writeTrustSensitive(bool value) {
    try {
      _file(_trustFileName).writeAsStringSync(value ? '1' : '0');
      return true;
    } on Object {
      return false;
    }
  }

  /// 测试用：把三个文件一次性清掉，避免用例之间互相影响。
  void reset() {
    clearCache();
    for (final String name in <String>[_lastSyncFileName, _trustFileName]) {
      try {
        final File file = _file(name);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } on Object {
        // 忽略。
      }
    }
  }
}
