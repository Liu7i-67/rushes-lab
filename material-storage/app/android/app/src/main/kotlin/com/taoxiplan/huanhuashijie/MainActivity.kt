package com.taoxiplan.huanhuashijie

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // §5.2 机型能力判定(无权限、无状态):getInfo → {manufacturer, model, sdkInt}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ms/device_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInfo" -> result.success(
                        mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "sdkInt" to Build.VERSION.SDK_INT,
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
