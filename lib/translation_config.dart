// 云端翻译配置。
//
// 密钥绝不写入仓库：默认值来自编译期 --dart-define，或运行时在 App 设置里填写。
// 配置只在进程内有效，不落盘、不随包分发；重装 App 后需要重新填一次。

/// 应用级配置单例，供翻译链、设置页与测试共享。
final TranslationConfig translationConfig = TranslationConfig();

class TranslationConfig {
  TranslationConfig({String? key, String? region, String? endpoint})
      : key = key ?? _envKey,
        region = region ?? _envRegion,
        endpoint = endpoint ?? _envEndpoint;

  /// 编译期注入仅用于自己构建自用包；公开仓库与分发包不要注入。
  static const String _envKey = String.fromEnvironment('AZURE_TRANSLATOR_KEY');
  static const String _envRegion =
      String.fromEnvironment('AZURE_TRANSLATOR_REGION');
  static const String _envEndpoint = String.fromEnvironment(
    'AZURE_TRANSLATOR_ENDPOINT',
    defaultValue: 'https://api.cognitive.microsofttranslator.com',
  );

  /// Azure 门户「密钥和终结点」页里的 Key 1。
  String key;

  /// 单服务 Translator 选「全球」时留空；选了具体区域则填，例如 eastasia。
  String region;

  /// 文本翻译终结点，末尾不带斜杠。
  String endpoint;

  bool get hasCloudKey => key.trim().isNotEmpty;

  /// 恢复编译期默认值，用于「关闭云端翻译」与测试隔离。
  void reset() {
    key = _envKey;
    region = _envRegion;
    endpoint = _envEndpoint;
  }
}
