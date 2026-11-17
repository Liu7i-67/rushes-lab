package com.taoxiplan.huanhuashijie

import android.os.Build
import com.xiaomi.livephoto.MiLivePhotoTools
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

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
        // 小米官方「动态照片 SDK」通道(docs/qdev/2026-11-16-xiaomi-motionphoto-sdk.md §4.3)。
        // 线程模型(钉子,勿省):mux 是秒级盘 IO(合成上限 150MB 源),isLivePhotoFile 也有
        // 头部读 IO——跑在 platform 主线程会冻结 UI/ANR;必须注册到后台 TaskQueue
        // (Flutter 官方机制)。既有 ms/device_info 只读 Build 字段所以无害,不可比照。
        val taskQueue = flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ms/motion_photo",
            StandardMethodCodec.INSTANCE,
            taskQueue,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(
                    try {
                        MiLivePhotoTools.isDeviceSupportLivePhoto()
                    } catch (e: Throwable) {
                        false
                    }
                )
                "isLivePhotoFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "缺少 path 参数", null)
                    } else {
                        // 产物语义校验 oracle:SDK 读文件头 XMP 判「MicroVideo/MotionPhoto」;
                        // 任何异常一律按 false(fail-safe)
                        result.success(
                            try {
                                MiLivePhotoTools.isLivePhotoFile(path)
                            } catch (e: Throwable) {
                                false
                            }
                        )
                    }
                }
                "mux" -> {
                    val img = call.argument<String>("imagePath")
                    val vid = call.argument<String>("videoPath")
                    val out = call.argument<String>("outPath")
                    if (img == null || vid == null || out == null) {
                        result.error("bad_args", "缺少 imagePath/videoPath/outPath 参数", null)
                    } else {
                        // StandardMessageCodec 把 <2^31 的 Dart int 解为 java.lang.Integer:
                        // 必须经 Number 取值,直接 argument<Long>/as Long 会 ClassCastException(钉子,勿改)
                        val ts = (call.argument<Number>("timestampUs") ?: 0L).toLong()
                        val ok = try {
                            MiLivePhotoTools.muxLivephoto(
                                applicationContext, img, vid, ts, out, /*insertMediaStore=*/false,
                            )
                        } catch (e: Throwable) {
                            result.error("mux_fail", e.toString(), null); return@setMethodCallHandler
                        }
                        result.success(ok)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
