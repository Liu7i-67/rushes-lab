/// 安卓实况图(Motion Photo)机型能力判定(§5.2,不引 device_info_plus——
/// 只要 3 个字段,避免为一个字段拉整包依赖;channel 侧见 MainActivity.kt 的
/// `ms/device_info`)。
///
/// 判定口径:
/// - manufacturer 小写 ∈ 白名单 且 sdkInt >= 31(Android 12)。初版白名单为
///   常量表(真机校准后可扩);HUAWEI/samsung/honor 初始均排除——D1 刻意
///   决策,勿因「厂商宣传都支持」而加,扩白名单须过真机验证(§8-D)。
/// - 注:redmi 机型 Build.MANUFACTURER 实报 "Xiaomi"、iQOO 实报 "vivo"
///   (redmi/iqoo 是 brand 不是 manufacturer),白名单里这两项永不命中属
///   预期——保留仅为语义自文档,实际由 xiaomi/vivo 覆盖。
/// - 显式前置 `!kIsWeb && Platform.isAndroid`:web/桌面 defaultSavePlatform
///   也返回 android(downloads.dart),不能只靠 channel 异常兜成 false。
/// - 进程内记忆化:**仅成功结果缓存**;channel 异常/null 每次重试不缓存,
///   防首次瞬断把 capable 机整个会话锁死在降级态。
/// - channel 不可用(异常/null)→ false(降级现状,永不因判定失败阻塞保存)。
library;

import 'dart:io';

import 'package:flutter/foundation.dart'
    show immutable, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

/// 机型信息最小抽象(模拟 device_info_plus 的 AndroidDeviceInfo 之子集)。
@immutable
class AndroidDeviceInfoLike {
  const AndroidDeviceInfoLike({
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
  });

  /// Build.MANUFACTURER,如 "Xiaomi"/"HUAWEI"(大小写不做约定,判定内归一)。
  final String manufacturer;

  /// Build.MODEL,如 "M2012K11AC"(当前白名单只用品牌+SDK 粒度,暂不消费)。
  final String model;

  /// Build.VERSION.SDK_INT(Android 12 = 31)。
  final int sdkInt;
}

/// 原生侧 `ms/device_info` channel(无权限、无状态,MainActivity.kt getInfo)。
const MethodChannel _deviceInfoChannel = MethodChannel('ms/device_info');

/// 初版白名单(常量表,真机校准后可扩;含 redmi/iqoo 仅语义自文档,见头注释)。
const Set<String> _capableManufacturers = {
  'google',
  'xiaomi',
  'redmi',
  'oppo',
  'oneplus',
  'realme',
  'vivo',
  'iqoo',
};

/// 纯判定:manufacturer 小写 ∈ 白名单 且 sdkInt >= 31。
bool isMotionPhotoCapable(AndroidDeviceInfoLike info) {
  final manufacturer = info.manufacturer.toLowerCase();
  return _capableManufacturers.contains(manufacturer) && info.sdkInt >= 31;
}

/// 成功结果记忆化(null = 尚无成功结果;失败路径永远不写入)。
AndroidDeviceInfoLike? _memoized;

/// 生产缺省:经 `ms/device_info` channel 读 {manufacturer, model, sdkInt}。
/// 字段缺失/类型不符 → null(与 channel 异常同走「false 且不缓存」语义)。
Future<AndroidDeviceInfoLike?> _fetchDeviceInfoFromChannel() async {
  final Object? raw = await _deviceInfoChannel.invokeMethod<dynamic>('getInfo');
  if (raw is! Map) return null;
  final Object? manufacturer = raw['manufacturer'];
  final Object? model = raw['model'];
  final Object? sdkInt = raw['sdkInt'];
  if (manufacturer is! String || model is! String || sdkInt is! int) {
    return null;
  }
  return AndroidDeviceInfoLike(
    manufacturer: manufacturer,
    model: model,
    sdkInt: sdkInt,
  );
}

/// 安卓实况图能力判定(下载侧分流入口,§5.4 `await motionPhotoCapable()`)。
///
/// - 非 Android(web/桌面)恒 false,不触 channel;
/// - 有成功结果记忆化时直接复用;否则经 channel(或注入件)取机型,
///   异常/null → false 且不缓存(下次重试),成功 → 写记忆化再判定。
///
/// [isAndroidPlatform]/[fetchDeviceInfo] 仅供单测注入:前者覆盖平台 gate
/// (测试宿主非 Android),后者覆盖 channel 调用(测试环境无通道);
/// 生产调用一律缺省走真实判定。配套重置件 [resetMotionPhotoCapabilityForTest]。
Future<bool> motionPhotoCapable({
  @visibleForTesting bool? isAndroidPlatform,
  @visibleForTesting Future<AndroidDeviceInfoLike?> Function()? fetchDeviceInfo,
}) async {
  final onAndroid = isAndroidPlatform ?? (!kIsWeb && Platform.isAndroid);
  if (!onAndroid) return false;

  final memo = _memoized;
  if (memo != null) return isMotionPhotoCapable(memo);

  final fetch = fetchDeviceInfo ?? _fetchDeviceInfoFromChannel;
  AndroidDeviceInfoLike? info;
  try {
    info = await fetch();
  } catch (_) {
    return false; // channel 异常:降级现状,false 不缓存(下次重试)
  }
  if (info == null) {
    return false; // channel 不可用/字段缺失:同上,false 不缓存
  }
  _memoized = info; // 仅成功结果缓存
  return isMotionPhotoCapable(info);
}

/// 清空成功记忆化(仅供单测隔离用例间状态,生产勿调)。
@visibleForTesting
void resetMotionPhotoCapabilityForTest() {
  _memoized = null;
}
