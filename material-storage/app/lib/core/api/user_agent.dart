import 'dart:io';

/// 客户端 UA:`msapp/<version> (<platform>)` —— 后端审计使用统计按此识别
/// 三端(msapp+android → android_app,msapp+ios → ios_app,见 usage-analytics
/// 方案 §3 platform CASE 规则)。
/// [version] 为空串/null 时输出 `msapp/ (android|ios)`,解析只依赖平台段。
/// [isIOS] 供单测注入(测试环境不依赖 dart:io Platform);默认 [Platform.isIOS]
/// 同步判定,非 iOS 一律归 android。
String buildClientUserAgent(String? version, {bool? isIOS}) =>
    'msapp/${version ?? ''} (${(isIOS ?? Platform.isIOS) ? 'ios' : 'android'})';
