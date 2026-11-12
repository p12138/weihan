import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // super 之后 window / rootViewController 才就绪，此时注册通道才拿得到 messenger。
    registerUpdateChannel()
    return launched
  }

  /// 与 Android 同名的 `weihan/update` 通道。
  ///
  /// iOS 不允许应用自己装未签名包，所以 installApk 恒返回 false，
  /// 由 Dart 侧改成「打开下载页 + 提示重签」；openUrl 真正有用：
  /// 把用户送到 NAS 上下载 IPA，或者送到 TestFlight。
  private func registerUpdateChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "weihan/update",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openUrl":
        guard
          let args = call.arguments as? [String: Any],
          let raw = args["url"] as? String,
          let url = URL(string: raw)
        else {
          result(FlutterError(code: "bad_args", message: "缺少 URL", details: nil))
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      case "installApk":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
