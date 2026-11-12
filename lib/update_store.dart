import 'dart:io';

/// 更新源地址与「上次静默检查时间」的落盘。
///
/// 和 `PaletteStore` 同样的取舍：不为此引入 shared_preferences 这种平台插件，
/// 只写一个纯文本小文件。丢了也无所谓——更新源回到默认值，下次还能手动改。
class UpdateStore {
  UpdateStore._();

  static const String _baseFileName = 'weihan_update_base.txt';
  static const String _checkFileName = 'weihan_update_last_check.txt';

  /// 构建期可注入的默认更新源：`--dart-define=UPDATE_BASE=https://…`。
  /// 没注入时为空，界面上显示「未配置」，不会去猜地址。
  static const String compiledBase = String.fromEnvironment('UPDATE_BASE');

  static File? _file(String name) {
    try {
      final Directory dir = Directory.systemTemp;
      if (!dir.existsSync()) {
        return null;
      }
      return File('${dir.path}${Platform.pathSeparator}$name');
    } on Object {
      return null;
    }
  }

  /// 用户填过的更新源；没填过（或文件丢了）就用构建期注入值。
  static String readBaseUrl() {
    final String fallback = compiledBase.trim();
    try {
      final File? file = _file(_baseFileName);
      if (file == null || !file.existsSync()) {
        return fallback;
      }
      final String text = file.readAsStringSync().trim();
      return text.isEmpty ? fallback : text;
    } on Object {
      return fallback;
    }
  }

  /// 写入更新源。传空字符串表示「清掉自定义值、回到构建期默认」。
  static bool writeBaseUrl(String url) {
    try {
      final File? file = _file(_baseFileName);
      if (file == null) {
        return false;
      }
      final String text = url.trim();
      if (text.isEmpty) {
        if (file.existsSync()) {
          file.deleteSync();
        }
        return true;
      }
      file.writeAsStringSync(text);
      return true;
    } on Object {
      return false;
    }
  }

  /// 上次静默检查的时间。用于节流：一天最多自动查一次，避免每次冷启动都打 NAS。
  static DateTime? readLastCheck() {
    try {
      final File? file = _file(_checkFileName);
      if (file == null || !file.existsSync()) {
        return null;
      }
      return DateTime.tryParse(file.readAsStringSync().trim());
    } on Object {
      return null;
    }
  }

  static bool writeLastCheck(DateTime at) {
    try {
      final File? file = _file(_checkFileName);
      if (file == null) {
        return false;
      }
      file.writeAsStringSync(at.toIso8601String());
      return true;
    } on Object {
      return false;
    }
  }
}
