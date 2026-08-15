package ai.deepseek.dsh_remote

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dsh_remote/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueue" -> {
                    try {
                        val url = call.argument<String>("url")!!
                        val filename = call.argument<String>("filename") ?: "download"
                        val title = call.argument<String>("title") ?: filename
                        result.success(enqueue(url, filename, title))
                    } catch (e: Exception) {
                        result.error("download_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 交给系统 DownloadManager：流式写入公共 Downloads 目录并显示通知，
     *  用户在通知/系统「下载」里打开（APK 可走系统安装器）。鉴权走 ?token query。 */
    private fun enqueue(url: String, filename: String, title: String): Long {
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle(title)
            setDescription("来自 DSH Remote")
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
        }
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return dm.enqueue(request)
    }
}
