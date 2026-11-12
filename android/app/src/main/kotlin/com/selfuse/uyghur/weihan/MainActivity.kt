package com.selfuse.uyghur.weihan

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 自更新需要的两个原生动作：调起系统安装器、打开下载页。
 *
 * 通道名与 Dart 侧 `PlatformUpdateInstaller` 一致（weihan/update）。
 * 不引入 open_filex / url_launcher：这两个插件会带来新的 AndroidX 约束，
 * 而本工程的插件版本是刻意锁死的，为一次装包去动整条工具链不划算。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "weihan/update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "缺少 APK 路径", null)
                        } else {
                            installApk(path, result)
                        }
                    }

                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("bad_args", "缺少 URL", null)
                        } else {
                            openUrl(url, result)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String, result: MethodChannel.Result) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("missing_file", "安装包不存在：$path", null)
                return
            }
            // Android 7 起禁止把 file:// 交给别的应用，必须用 FileProvider
            // 生成 content:// 并显式授予读权限，否则系统安装器会直接拒绝。
            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error(
                "install_failed",
                error.message ?: "调起系统安装器失败",
                null,
            )
        }
    }

    private fun openUrl(url: String, result: MethodChannel.Result) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: "打不开链接", null)
        }
    }
}
