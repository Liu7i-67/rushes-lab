/// MaintenanceBannerController — 维护横幅轮询(B9 §8.12,web MaintenanceBanner
/// 同款状态机移动版):**前台即轮询、不分登录态**(与 UnreadPoller 共用
/// PollingController 节拍但门控不同——仅要求探活就绪拿到 API,不要求已登录;
/// 登录页同样轮询展示)。周期 8s(web POLL_MS 同款)。
///
/// 状态机(web 逐条对齐):
/// - active=true → maintaining(不可关强提示;重复 tick 内容原地刷新);
/// - active true→false → justFinished(「升级完成」),6s 后自动回 idle;
/// - **网络错误不误判完成**:GET 失败(部署重启窗口的常态)按 lastKnownActive
///   兜底——先前 active 保持 maintaining、先前非 active 静默,均不触发完成;
/// - 非 200(反代异常页)同网络错误口径处理。
library;

import 'dart:async';

import '../api/ms_api.dart';
import '../polling_controller.dart';
import '../session.dart';

/// GET /maintenance/banner 响应契约(api/app/routers/maintenance.py 实码;
/// 公开免鉴权,无 banner 时也 200 {active:false})。
class MaintenanceBannerInfo {
  MaintenanceBannerInfo({
    required this.active,
    this.message,
    this.issues = const <(int, String)>[],
    this.startedAt,
    this.endsAt,
  });

  factory MaintenanceBannerInfo.fromJson(Map<String, dynamic> j) =>
      MaintenanceBannerInfo(
        active: (j['active'] ?? false) as bool,
        message: j['message'] as String?,
        issues: ((j['issues'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => (
                  (e['number'] ?? 0) as int,
                  '${e['summary'] ?? ''}',
                ))
            .toList(),
        startedAt: j['started_at'] as String?,
        endsAt: j['ends_at'] as String?,
      );

  final bool active;
  final String? message;

  /// 本次部署解决的 issue 简报(#号 + 一句话)。
  final List<(int, String)> issues;
  final String? startedAt;
  final String? endsAt;
}

enum MaintenancePhase { idle, maintaining, justFinished }

class MaintenanceBannerController extends PollingController {
  MaintenanceBannerController(
      {super.interval = const Duration(seconds: 8), this.api});

  /// 测试注入;生产为 null → 读 session.api(探活后才就绪)。
  final MsApi? api;

  MsApi? get effectiveApi => api ?? session.api;

  MaintenancePhase _phase = MaintenancePhase.idle;
  MaintenanceBannerInfo? info;
  bool _lastKnownActive = false;
  Timer? _finishTimer;

  MaintenancePhase get phase => _phase;

  /// 前台即轮询、不分登录态(§8.12 钉子:与通知轮询门控的唯一差别)。
  @override
  bool canPoll() => effectiveApi != null;

  @override
  Future<void> performTick() async {
    final api = effectiveApi;
    if (api == null) return;
    final MaintenanceBannerInfo banner;
    try {
      final r = await api.http.get('/api/v1/maintenance/banner');
      // 非 200(反代 5xx 异常页等)不当完成也不当激活,等下一拍
      if (r.statusCode != 200) return;
      banner = MaintenanceBannerInfo.fromJson(r.data as Map<String, dynamic>);
    } catch (_) {
      // 网络错误(deploy 重启窗口):lastKnownActive 兜底,维持现状不误判
      return;
    }
    _apply(banner);
  }

  /// 状态机推演(独立方法便于单测:成功响应 → 相位/文案按 web 语义流转)。
  void apply(MaintenanceBannerInfo banner) => _apply(banner);

  void _apply(MaintenanceBannerInfo banner) {
    final wasActive = _lastKnownActive;
    _lastKnownActive = banner.active;
    _finishTimer?.cancel();
    _finishTimer = null;
    if (banner.active) {
      info = banner;
      _phase = MaintenancePhase.maintaining;
    } else if (wasActive) {
      // 刚结束:「升级完成」6s 自动关(web COMPLETE_TOAST_MS 同款)
      _phase = MaintenancePhase.justFinished;
      _finishTimer = Timer(const Duration(seconds: 6), () {
        _finishTimer = null;
        _setPhase(MaintenancePhase.idle);
      });
    } else {
      info = null;
      _phase = MaintenancePhase.idle;
    }
    notifyListeners();
  }

  void _setPhase(MaintenancePhase p) {
    _phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _finishTimer?.cancel();
    super.dispose();
  }
}

/// 全局单例(main.dart attach + Session 门控接线;§8.12 登录页/主界面均挂)。
final MaintenanceBannerController maintenanceBanner =
    MaintenanceBannerController();
