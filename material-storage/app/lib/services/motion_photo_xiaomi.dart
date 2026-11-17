/// 小米官方动态照片 SDK 接入 Dart 侧(2026-11-16 方案 §4.4,包 B 新件):经
/// `ms/motion_photo` channel 调原生 com.xiaomi.camera:livephoto:1.0.3(原生侧
/// MainActivity.kt,注册在后台 TaskQueue——mux 是秒级盘 IO,防主线程冻结)。
///
/// 分流语义(§3,失败安全方向——非 xiaomi 支路的意外异常≈今日行为):
/// - 非 Android / device_info 异常或字段缺失 / 非 xiaomi → composer 返回 null
///   (一切照旧 flm,其他机型零影响);
/// - xiaomi + isSupported=false/通道异常(MIUI/旧相册不识别三方合成动图)→
///   supported=false(编排层走 fallbackLegacyDownload,D1 双落盘,D2)——通道
///   异常与 false/非 bool 同列落 D1(§3-5):flm 产物在小米相册必不播(本周期
///   bug 本体),D1 严格更优,不随整体兜底收成 null;
/// - xiaomi + isSupported=true → generate(mux 通道合成)+ verifyProduct
///   (isLivePhotoFile 产物语义 oracle)。
///
/// 测试注入缝(对齐 capability 模块 isAndroidPlatform/fetchDeviceInfo 先例):
/// 涉通道函数一律带 @visibleForTesting 注入参,缺省=真实通道实现,测试宿主
/// 零平台通道。依赖方向:motion_photo_save.dart → 本件单向(generate 字段用
/// 结构性函数类型=MotionPhotoGenerator 的展开形,本件不 import 回 save.dart)。
library;

import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'motion_photo.dart' show xmpHeadWindow;
import 'motion_photo_verify.dart' show deleteQuietly, readFileRange;

/// 原生侧 `ms/motion_photo` channel(isSupported / mux / isLivePhotoFile)。
const MethodChannel _sdkChannel = MethodChannel('ms/motion_photo');

/// 原生侧 `ms/device_info` channel(机型判定自持一次调用,不复用 capability
/// 模块的私有记忆化——§3-3 成本声明:白名单机型每次 livp 下载多一次轻量 RPC,
/// 刻意不优化,避免动 capability 模块违反零改动清单)。
const MethodChannel _deviceInfoChannel = MethodChannel('ms/device_info');

/// 小米 composer(§4.5 步骤 -1 的分流点):null=非 xiaomi/非 Android/
/// device_info 通道异常(→ 一切照旧 flm);supported=false=小米+MIUI/旧相册
/// (→ D1 双落盘);supported=true 时 generate/verifyProduct 必非空。generate
/// 字段为**结构性函数类型**(与 save.dart 的 MotionPhotoGenerator 同形,可互相
/// 赋值)——防新件 import 回 save.dart 形成互指,依赖方向保持 save→xiaomi 单向。
typedef XiaomiComposer =
    Future<
      ({
        bool supported,
        Future<String> Function({
          required String imagePath,
          required String videoPath,
        })?
        generate,
        Future<bool> Function(String productPath)? verifyProduct,
      })?
    >
    Function();

/// composer 返回 record 的类型别名(与 [XiaomiComposer] 内联 record 同形,供
/// probe 实现显式标注返回类型,record 字面量类型推断免歧义)。
typedef _XiaomiProbeResult = ({
  bool supported,
  Future<String> Function({
    required String imagePath,
    required String videoPath,
  })?
  generate,
  Future<bool> Function(String productPath)? verifyProduct,
});

/// `ms/motion_photo` invokeMethod 缺省封装(invokeSdk 注入参的缺省值)。
Future<Object?> _defaultSdkInvoke(
  String method, [
  Map<String, Object?>? args,
]) => _sdkChannel.invokeMethod<Object?>(method, args);

/// `ms/device_info` getInfo 缺省封装:字段缺失/类型不符 → null(与通道异常同走
/// 「null→照旧 flm」语义;不缓存不记忆化,每次重试)。
Future<Map<Object?, Object?>?> _defaultFetchDeviceInfo() async {
  final Object? raw = await _deviceInfoChannel.invokeMethod<dynamic>('getInfo');
  return raw is Map<Object?, Object?> ? raw : null;
}

/// 生产缺省 composer(§3 probe 五分支语义;实现体整体再兜一层 try/catch(_)→
/// null——只兜 device_info 之外「分支枚举之外的意外异常」≈今日行为,对齐
/// capability 件 catch 全兜先例;isSupported 通道异常是 §3-5 枚举内分支,单独
/// 收口为 supported=false 落 D1,不经整体兜底,见下)。注入参仅供单测覆盖平台
/// 门/通道(测试宿主零平台通道),生产调用一律缺省走真实实现。
XiaomiComposer defaultXiaomiComposer({
  @visibleForTesting bool? isAndroidPlatform,
  @visibleForTesting Future<Map<Object?, Object?>?> Function()? fetchDeviceInfo,
  @visibleForTesting
  Future<Object?> Function(String method, [Map<String, Object?>? args])?
  invokeSdk,
}) {
  Future<_XiaomiProbeResult?> probe() async {
    try {
      // §3-1 显式平台门(web/桌面/测试宿主 → null,不靠通道异常兜;iOS 上
      // flm 本就不被调用)
      final onAndroid = isAndroidPlatform ?? (!kIsWeb && Platform.isAndroid);
      if (!onAndroid) return null;
      // §3-2 device_info 一次无状态调用(异常/字段缺失 → null,每次重试)
      final info = await (fetchDeviceInfo ?? _defaultFetchDeviceInfo)();
      // §3-3 manufacturer 归一后 ≠ xiaomi → null(白名单其余机型照旧 flm,
      // 零影响;redmi 实报 manufacturer="Xiaomi",由本分支一并覆盖)
      final manufacturer = info?['manufacturer'];
      if (manufacturer is! String || manufacturer.toLowerCase() != 'xiaomi') {
        return null;
      }
      // §3-4/5 isSupported:false/通道异常/返回非 bool → supported=false(D2)。
      // 通道异常在此单独 try/catch 收口(不落外层整体兜底):§3-5 与 false/
      // 非 bool 同列落 D1——flm 产物在小米相册必不播,D1 双落盘严格更优。
      final invoke = invokeSdk ?? _defaultSdkInvoke;
      bool supported;
      try {
        final r = await invoke('isSupported');
        supported = r is bool && r;
      } catch (_) {
        supported = false; // 一切异常(含 TimeoutException 等)→ D1,勿上抛
      }
      if (!supported) {
        return (supported: false, generate: null, verifyProduct: null);
      }
      return (
        supported: true,
        generate: _xiaomiGenerate(invoke),
        verifyProduct: (productPath) =>
            defaultVerifyXiaomiProduct(productPath, invokeSdk: invoke),
      );
    } catch (_) {
      // 只兜 device_info 之外的分支枚举外意外异常 ≈ 今日行为(isSupported 通道
      // 异常已在上单独收口为 supported=false 落 D1,不经此处)。
      return null;
    }
  }

  return probe;
}

/// 生成器适配闭包(签名对齐 save.dart 的 MotionPhotoGenerator 展开形):系统
/// 临时目录生成 out 路径(钉 `<时间戳>_motion.jpg` 后缀——入相册 MIME 由 title
/// 的 .jpg 决定不受影响,钉后缀只为真机排障时容器语义零歧义)→ 提取时间戳
/// (null 兜底 0,D3)→ channel mux → 返回 outPath。成功路径产物由编排层既有
/// flmProduct + cleanIntermediates 登记清理(符号名沿用不重命名);失败路径
/// 编排层拿不到路径,删除责任在 mux 封装内部。
Future<String> Function({required String imagePath, required String videoPath})
_xiaomiGenerate(
  Future<Object?> Function(String method, [Map<String, Object?>? args]) invoke,
) {
  return ({required imagePath, required videoPath}) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final outPath = '${Directory.systemTemp.path}/${stamp}_motion.jpg';
    final ts = await extractPresentationTimestampUs(File(imagePath)) ?? 0;
    return muxXiaomiLivePhoto(
      imagePath: imagePath,
      videoPath: videoPath,
      timestampUs: ts,
      outPath: outPath,
      invokeSdk: invoke,
    );
  };
}

/// channel `mux` 封装(SDK muxLivephoto 返回布尔不抛异常;Kotlin 侧防虚拟机
/// 错误外溢的 try/catch → 通道 error 形态)。成功原样返回 [outPath];
/// ok==false 或通道异常 → 先幂等静默删 [outPath] 半成品(防孤儿占盘)→
/// AppLog.error → 抛带 xiaomi 前缀的 Exception(交编排层既有 catch 走 D1;
/// 既有 catch 文案不改=最小化 diff,reason 带 xiaomi 前缀+前条日志可分诊)。
Future<String> muxXiaomiLivePhoto({
  required String imagePath,
  required String videoPath,
  required int timestampUs,
  required String outPath,
  @visibleForTesting
  Future<Object?> Function(String method, [Map<String, Object?>? args])?
  invokeSdk,
}) async {
  final invoke = invokeSdk ?? _defaultSdkInvoke;
  Object? err;
  try {
    final ok = await invoke('mux', {
      'imagePath': imagePath,
      'videoPath': videoPath,
      // 装箱钉子(§4.3):Dart int 原样透传,>2^31 值无损;原生侧必须经
      // Number 取值(直接 argument<Long> 会 ClassCastException)。
      'timestampUs': timestampUs,
      'outPath': outPath,
    });
    if (ok is bool && ok) return outPath;
    err = 'mux 返回 false';
  } catch (e) {
    err = e;
  }
  await deleteQuietly(File(outPath));
  AppLog.error('motion', 'xiaomi mux 失败', err);
  throw Exception('xiaomi mux 失败:$err');
}

/// channel `isLivePhotoFile` 封装(SDK 产物语义层校验 oracle,§2:SDK 自读文件
/// 头 XMP 判「MicroVideo/MotionPhoto」关键词)。任何异常/返回非 bool 按 false
/// (fail-safe,对齐 verify 件全兜语义)。
Future<bool> defaultVerifyXiaomiProduct(
  String productPath, {
  @visibleForTesting
  Future<Object?> Function(String method, [Map<String, Object?>? args])?
  invokeSdk,
}) async {
  try {
    final ok = await (invokeSdk ?? _defaultSdkInvoke)('isLivePhotoFile', {
      'path': productPath,
    });
    return ok is bool && ok;
  } catch (_) {
    return false;
  }
}

/// livp 快路径 jpg 的 PresentationTimestampUs 提取(纯函数,定点读头 256KB,
/// 禁全量回读):`GCamera:MotionPhotoPresentationTimestampUs` 优先、
/// `GCamera:MicroVideoPresentationTimestampUs` 次之(值容忍单/双引号),无命中
/// → null(编排层兜底 0,D3:安卓上传源 livp 快路径 jpg 带残留 XMP 原值可信;
/// iOS 源补抓 unpacked 的 jpg 无 motion XMP → null)。任何 IO/解析异常 → null。
Future<int?> extractPresentationTimestampUs(File image) async {
  try {
    final size = await image.length();
    final windowEnd = size < xmpHeadWindow ? size : xmpHeadWindow;
    final s = utf8.decode(
      await readFileRange(image, 0, windowEnd),
      allowMalformed: true,
    );
    final m =
        _motionTimestampUsPattern.firstMatch(s) ??
        _microTimestampUsPattern.firstMatch(s);
    return m == null ? null : int.tryParse(m.group(1)!);
  } catch (_) {
    return null;
  }
}

/// 时间戳属性正则(值容单/双引号;两条按序尝试保 MotionPhoto 优先)。
final RegExp _motionTimestampUsPattern = RegExp(
  'GCamera:MotionPhotoPresentationTimestampUs=[\'"]([0-9]+)[\'"]',
);

final RegExp _microTimestampUsPattern = RegExp(
  "GCamera:MicroVideoPresentationTimestampUs=[\"']([0-9]+)[\"']",
);
