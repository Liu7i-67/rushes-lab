/// AppVersionInfo — 版本 JSON(`huanhuashijie/app_version.json`,F1-5 契约)
/// 解析模型(F2-2)。防御式解析(对齐 qi_webview_tool 的 fromJson 风格):
/// - build 缺失/类型异常 = 0;changelog 缺失/类型异常 = '';
/// - force 缺失/类型异常 = false(本期仅透传不生效,D5);
/// - version 或 android.url 缺失/为空/类型异常 → FormatException,
///   即「无有效更新信息」(自动检查静默吞掉,手动检查 SnackBar 兜底)。
library;

class AppVersionInfo {
  const AppVersionInfo({
    required this.version,
    required this.build,
    required this.changelog,
    required this.force,
    required this.androidUrl,
  });

  /// 远端最新版本号(x.y.z,不含 build)。
  final String version;

  /// 远端 build 号(缺失 = 0;仅与本地 build 决胜 version 平局)。
  final int build;

  /// 更新说明(缺失 = '';空串时确认弹窗不显示正文区)。
  final String changelog;

  /// 强更标记(本期仅透传不生效,UI 不做强制分支)。
  final bool force;

  /// Android 版本化 APK 直链(公有读,无签名参数)。
  final String androidUrl;

  factory AppVersionInfo.fromJson(Map<dynamic, dynamic> json) {
    final version = json['version'];
    if (version is! String || version.isEmpty) {
      throw const FormatException('version 缺失/为空/类型错误');
    }
    final android = json['android'];
    final url = android is Map ? android['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const FormatException('android.url 缺失/为空/类型错误');
    }
    return AppVersionInfo(
      version: version,
      build: json['build'] is int ? json['build'] as int : 0,
      changelog: json['changelog'] is String ? json['changelog'] as String : '',
      force: json['force'] is bool ? json['force'] as bool : false,
      androidUrl: url,
    );
  }
}
