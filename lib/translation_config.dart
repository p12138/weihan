// 云端翻译配置。
//
// 密钥绝不写入仓库：默认值来自编译期 --dart-define，或运行时在 App 设置里填写。
// 配置只在进程内有效，不落盘、不随包分发；重装 App 后需要重新填一次。

/// 可用的文本翻译后端。切换后端不需要重新出包。
enum TranslationProvider {
  niuTrans('小牛翻译', 'https://api.niutrans.com'),
  azure('Azure Translator', 'https://api.cognitive.microsofttranslator.com'),
  demo('仅演示词库', '');

  const TranslationProvider(this.label, this.defaultEndpoint);

  /// 设置页显示名。
  final String label;

  /// 未自定义终结点时使用的地址。
  final String defaultEndpoint;
}

/// 应用级配置单例，供翻译链、设置页与测试共享。
final TranslationConfig translationConfig = TranslationConfig();

class TranslationConfig {
  TranslationConfig({
    TranslationProvider? provider,
    String? appId,
    String? key,
    String? region,
    String? endpoint,
    String? ugCode,
  })  : provider = provider ?? _envProvider,
        appId = appId ?? _envAppId,
        key = key ?? _envKey,
        region = region ?? _envRegion,
        endpoint = endpoint ?? _envEndpoint,
        ugCode = ugCode ?? _envUgCode;

  /// 编译期注入仅用于自己构建自用包；公开仓库与分发包不要注入。
  static const String _envAppId = String.fromEnvironment('NIUTRANS_APP_ID');
  static const String _envKey = String.fromEnvironment('TRANSLATOR_API_KEY');
  static const String _envRegion =
      String.fromEnvironment('AZURE_TRANSLATOR_REGION');
  static const String _envEndpoint =
      String.fromEnvironment('TRANSLATOR_ENDPOINT');
  // CI live check 实测：to=uy + 毫秒时间戳可用，ug 返回空译文。
  static const String _envUgCode =
      String.fromEnvironment('NIUTRANS_UG_CODE', defaultValue: 'uy');
  static const TranslationProvider _envProvider =
      bool.fromEnvironment('USE_AZURE_TRANSLATOR')
          ? TranslationProvider.azure
          : TranslationProvider.niuTrans;

  /// 当前后端。设置页可随时切换，翻译链每次调用都会重新读取。
  TranslationProvider provider;

  /// 小牛翻译控制台「API 应用」页的 APPID。
  String appId;

  /// 小牛的 API-KEY，或 Azure 门户的 Key 1。
  String key;

  /// Azure 专用：单服务 Translator 选「全球」时留空，具体区域如 eastasia。
  String region;

  /// 自定义终结点，末尾不带斜杠；留空则用当前后端的默认地址。
  /// 阶段 2 的 NAS 代理上线后，这里填 NAS 地址即可，App 不用重新出包。
  String endpoint;

  /// 小牛的维语语种代码。官方文档与开源模型分别出现 ug / uy，
  /// 由 CI 的 live check 探测后可通过 --dart-define 覆盖。
  String ugCode;

  /// 最近一次云端调用的可读诊断信息（不含密钥），供界面显示真实失败原因。
  /// 属于运行时状态，不会落盘、不随包分发。
  String lastDiagnostic = '';

  /// 是否填了任意密钥（保留给 Azure 实现与旧断言）。
  bool get hasCloudKey => key.trim().isNotEmpty;

  /// 当前后端是否具备发起真实请求的最低条件。
  bool get hasCloudConfig {
    switch (provider) {
      case TranslationProvider.demo:
        return false;
      case TranslationProvider.niuTrans:
        return appId.trim().isNotEmpty && key.trim().isNotEmpty;
      case TranslationProvider.azure:
        return key.trim().isNotEmpty;
    }
  }

  /// 实际使用的终结点，末尾不带斜杠。
  String get effectiveEndpoint {
    final String custom = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    return custom.isNotEmpty ? custom : provider.defaultEndpoint;
  }

  /// 恢复编译期默认值，用于「关闭云端翻译」与测试隔离。
  void reset() {
    provider = _envProvider;
    appId = _envAppId;
    key = _envKey;
    region = _envRegion;
    endpoint = _envEndpoint;
    ugCode = _envUgCode;
    lastDiagnostic = '';
  }
}
