import 'dart:io';

/// 主题选择的落盘。
///
/// 为什么不用 shared_preferences：那是一个平台插件，会带来 Android
/// compileSdk / iOS Pod 的新约束，而本工程的插件版本是刻意锁死的
/// （见 pubspec 的 dependency_overrides）。为了记住一个主题名去动
/// 整条工具链不值当，这里只写一个纯文本文件。
///
/// 位置取系统临时目录（Android 上是应用自己的 cache 目录，iOS 上是沙盒内
/// 的 tmp）。被系统清掉也无所谓：读不到就回默认配色，不影响任何功能。
class PaletteStore {
  PaletteStore._();

  static const String _fileName = 'weihan_palette.txt';

  static File? _file() {
    try {
      final Directory dir = Directory.systemTemp;
      if (!dir.existsSync()) {
        return null;
      }
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } on Object {
      return null;
    }
  }

  /// 读上次选的主题 id；没有或读不出来返回 null。
  static String? read() {
    try {
      final File? file = _file();
      if (file == null || !file.existsSync()) {
        return null;
      }
      final String id = file.readAsStringSync().trim();
      return id.isEmpty ? null : id;
    } on Object {
      return null;
    }
  }

  /// 写入失败不抛出：记住偏好是锦上添花，不能让切主题报错。
  static bool write(String id) {
    try {
      final File? file = _file();
      if (file == null) {
        return false;
      }
      file.writeAsStringSync(id);
      return true;
    } on Object {
      return false;
    }
  }
}
