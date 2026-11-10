// 语音服务（讯飞 WebAPI）运行时配置。
//
// 凭证绝不写入仓库：默认值来自编译期 --dart-define，或运行时在 App 设置里填写。
// 与 translation_config.dart 一样，只在进程内存里有效，不落盘、不随包分发。
// 长期方案是把这些凭证挪到 NAS 代理；届时只需把 endpoint 指向代理地址。

/// 应用级语音配置单例。
final SpeechConfig speechConfig = SpeechConfig();

class SpeechConfig {
  SpeechConfig({
    String? appId,
    String? apiKey,
    String? apiSecret,
    String? ugVcn,
    String? zhVcn,
    String? endpoint,
  })  : appId = appId ?? _envAppId,
        apiKey = apiKey ?? _envApiKey,
        apiSecret = apiSecret ?? _envApiSecret,
        ugVcn = ugVcn ?? _envUgVcn,
        zhVcn = zhVcn ?? _envZhVcn,
        endpoint = endpoint ?? _envEndpoint;

  /// 编译期注入仅用于自己构建自用包；公开仓库与分发包不要注入。
  static const String _envAppId = String.fromEnvironment('XFYUN_APP_ID');
  static const String _envApiKey = String.fromEnvironment('XFYUN_API_KEY');
  static const String _envApiSecret =
      String.fromEnvironment('XFYUN_API_SECRET');

  /// 维语发音人的参数值由讯飞控制台「发音人管理」给出，可能随账号变化，
  /// 因此不硬编码；中文发音人用官方免费基础音色。
  static const String _envUgVcn = String.fromEnvironment('XFYUN_UG_VCN');
  static const String _envZhVcn =
      String.fromEnvironment('XFYUN_ZH_VCN', defaultValue: 'x4_xiaoyan');
  static const String _envEndpoint =
      String.fromEnvironment('XFYUN_SPEECH_ENDPOINT');

  /// 讯飞控制台应用的 APPID。
  String appId;

  /// 控制台服务的 APIKey（32 位）。
  String apiKey;

  /// 控制台服务的 APISecret（32 位），只用于本地 HMAC 签名。
  String apiSecret;

  /// 维吾尔语发音人参数值 vcn；为空时维语朗读不可用，但不影响识别与文字翻译。
  String ugVcn;

  /// 中文发音人参数值 vcn。
  String zhVcn;

  /// 自建 NAS 代理的完整 wss 地址（可选）。留空则用讯飞官方端点。
  /// 代理需自行保管 APISecret 并转发 WebSocket，App 侧无需改动。
  String endpoint;

  /// 最近一次语音调用的可读诊断（不含任何凭证），供界面提示。
  String lastDiagnostic = '';

  /// 是否具备发起语音识别 / 合成的最低条件。
  bool get hasConfig =>
      appId.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      apiSecret.trim().isNotEmpty;

  /// 当前语言能否朗读。
  bool canSpeak(bool isUyghur) =>
      hasConfig && (isUyghur ? ugVcn.trim().isNotEmpty : zhVcn.trim().isNotEmpty);

  /// 恢复编译期默认值，用于「关闭语音」与测试隔离。
  void reset() {
    appId = _envAppId;
    apiKey = _envApiKey;
    apiSecret = _envApiSecret;
    ugVcn = _envUgVcn;
    zhVcn = _envZhVcn;
    endpoint = _envEndpoint;
    lastDiagnostic = '';
  }
}
