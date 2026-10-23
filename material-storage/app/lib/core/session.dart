/// Session — 探活 + baseUrl + cookie 持久化 + Me 缓存 + 401 去抖(§4/§4.1 定稿)。
///
/// 冷启动按序探测 `GET /api/v1/maintenance/banner`(免鉴权,connectTimeout 3s):
///   ① --dart-define=MS_API_BASE(仅开发构建,不进 UI)
///   ② http://192.168.110.221(内网)③ https://bucket.taoxiplan.com(公网)
/// 命中即用;全失败 → 登录页「服务不可达 · 重试」(重按重探)。
/// 运行中不热切换 baseUrl;cookie 会话持久化(重启免登录)。
library;

import 'dart:async';
import 'dart:io' show Directory;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey, NavigatorState;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../services/app_log.dart';
import 'api/ms_api.dart';
import 'error_report/error_report_controller.dart';

/// dart-define 注入的开发口(不在 UI 呈现;47.108.196.211 预设已删除)。
const kDartDefineApiBase =
    String.fromEnvironment('MS_API_BASE', defaultValue: '');
const kIntranetEntry = 'http://192.168.110.221';
const kPublicEntry = 'https://bucket.taoxiplan.com';

/// 探活路径(2026-10-20 真机验收实测修正):不用 `/healthz`——它被跳板机
/// nginx 反代 403 拦截(仅隔离栈直连容器时可用,真实入口链路从不放行)。
/// 改用 web MaintenanceBanner 每 8s 在轮询的公开免鉴权端点
/// `/api/v1/maintenance/banner`(无 banner 时也返回 200 空数据),反代链路必然放行。
const kProbePath = '/api/v1/maintenance/banner';

/// §4 定稿候选序;dart-define 优先,未注入则内网→公网。
List<String> defaultProbeCandidates() => [
      if (kDartDefineApiBase.isNotEmpty) kDartDefineApiBase,
      kIntranetEntry,
      kPublicEntry,
    ];

enum SessionPhase { probing, unreachable, ready }

/// 单飞闸门:窗口期内首个调用方拿 true,其余 false(401 并发去抖用)。
class SingleFlightGate {
  SingleFlightGate(this.window);

  final Duration window;
  Timer? _t;

  bool acquire() {
    if (_t != null) return false;
    _t = Timer(window, () => _t = null);
    return true;
  }

  void reset() {
    _t?.cancel();
    _t = null;
  }
}

class Session extends ChangeNotifier {
  Session();

  final navigatorKey = GlobalKey<NavigatorState>();

  SessionPhase phase = SessionPhase.probing;
  String? baseUrl;

  /// 当前入口标识(我的页只读展示):内网 / 公网 / 指定(dart-define)。
  String entryLabel = '';
  MsApi? api;
  Me? me;

  CookieJar? _persistentJar;

  /// cookie 落盘目录(R4b:restore 失败日志要核「目录是否存在」,存下路径
  /// 供存在性检查;null=持久化未初始化或初始化失败)。
  String? _cookieDirPath;
  bool _probing = false;
  final _expiredGate = SingleFlightGate(const Duration(seconds: 1));

  /// Me 缓存标脏(B9 遗留清偿):改密成功但紧随的 me() 刷新失败时置 true——
  /// 缓存里的 must_change_password 已不可信,下次 [restore] 强制重拉兜底,
  /// 成功即清。观察入口 [meStale] 供测试。
  bool _meStale = false;

  bool get meStale => _meStale;

  /// 会话清空钩子(B2 遗留解耦:core 不再 import features——缩略图 URL 缓存
  /// 等特性侧资源经此挂清理回调,main.dart 注册,logout/401 统一触发)。
  final _clearHooks = <void Function()>[];

  void addSessionClearHook(void Function() hook) => _clearHooks.add(hook);

  void _runClearHooks() {
    for (final h in _clearHooks) {
      try {
        h();
      } catch (_) {/* 钩子失败不阻断登出 */}
    }
  }

  bool get mustChangePassword => me?.mustChangePassword ?? false;

  /// 冷启动探活:按序 GET [kProbePath],命中(HTTP 200)即用;全失败 → unreachable。
  /// [candidates] 供单测注入;生产走 [defaultProbeCandidates]。
  Future<void> probe({List<String>? candidates}) async {
    if (_probing) return;
    _probing = true;
    _setPhase(SessionPhase.probing);
    try {
      await initPersistence();
      for (final base in candidates ?? defaultProbeCandidates()) {
        try {
          final r = await Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          )).get<dynamic>('$base$kProbePath');
          // 4xx(如反代 403)/5xx:默认 validateStatus(2xx)会抛 DioException →
          // 走 catch 换下一个;statusCode==200 再显式兜底(即便 validateStatus
          // 被放宽,4xx 也不算命中)。banner 恒 200,判定语义即「HTTP 200」。
          if (r.statusCode == 200) {
            _activate(base);
            return;
          }
        } catch (_) {/* 换下一个候选 */}
      }
      _setPhase(SessionPhase.unreachable);
    } finally {
      _probing = false;
    }
  }

  void _activate(String base) {
    baseUrl = base;
    entryLabel = base == kIntranetEntry
        ? '内网'
        : base == kPublicEntry
            ? '公网'
            : '指定';
    api = MsApi(
      baseUrl: base,
      jar: _persistentJar ?? CookieJar(),
      onSessionExpired: handleSessionExpired,
      // 5xx/网络异常交全局报错页(门槛判定在 controller 内;core 内互引,
      // 不违反 core→features 解耦约定)
      onApiError: errorReporter.onApiError,
      onNetworkError: errorReporter.onNetworkError,
    );
    _setPhase(SessionPhase.ready);
  }

  /// cookie 会话恢复(重启免登录);失败=未登录,属正常态。
  /// 标脏时强制重拉(改密后刷新失败缓存的 must_change_password 不可信)。
  Future<Me?> restore() async {
    try {
      me = await api!.auth.me();
      _meStale = false;
    } catch (e) {
      // R4b(mobile-ux-polish-2):恢复失败不再静默吞——日志留痕(异常、持久化
      // jar 是否就绪、cookie 目录是否存在、statusCode 若可用),供企微日志推送
      // 定位「切出重开要求重登」(最可能=冷启动恢复链路失败)。恢复语义不变:
      // 失败仍 me=null 留登录页。
      final jarReady = _persistentJar != null;
      var cookieDirExists = false;
      final dirPath = _cookieDirPath;
      if (dirPath != null) {
        try {
          cookieDirExists = Directory(dirPath).existsSync();
        } catch (_) {/* 目录状态查不出也照记日志 */}
      }
      final status = e is ApiException ? e.status : null;
      AppLog.error(
        'session',
        '会话恢复失败(jar就绪=$jarReady, cookie目录存在=$cookieDirExists, '
            'status=$status)',
        e,
      );
      me = null;
    }
    notifyListeners();
    return me;
  }

  Future<Me> login(String username, String password) async {
    final m = await api!.auth.login(username, password);
    me = m;
    _meStale = false; // 登录响应即新鲜 Me,标脏态一并解除
    notifyListeners();
    return m;
  }

  /// 改密成功后刷新 Me(must_change_password 置否,cookie 会话不失效)。
  /// 刷新失败不吞(B9 遗留清偿):日志留痕 + 会话标脏,下次 [restore] 强制
  /// 重拉兜底;改密本身已生效,此处失败不向调用方报错(页面语义=改密成功)。
  Future<void> changePassword(String oldPassword, String newPassword) async {
    await api!.auth.changePassword(
        oldPassword: oldPassword, newPassword: newPassword);
    try {
      me = await api!.auth.me();
      _meStale = false;
    } catch (e) {
      AppLog.error('session', '改密成功但刷新 Me 失败(缓存标脏,下次访问兜底)', e);
      _meStale = true;
    }
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api?.auth.logout();
    } catch (_) {}
    me = null;
    _runClearHooks(); // B2 遗留解耦:预签缩略图 URL 不跨会话残留(过期前仍可直连)
    await _clearSessionCookie();
    notifyListeners();
  }

  /// 401 单次触发(去抖,并发多请求只走一次):清会话跳登录(§4.1)。
  Future<void> handleSessionExpired() async {
    if (!_expiredGate.acquire() || me == null) return;
    AppLog.info('session', '会话失效(401)→ 清会话回登录页');
    me = null;
    _runClearHooks(); // 与 logout 同口径,换账号前清特性侧缓存
    await _clearSessionCookie();
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/', (r) => false);
    notifyListeners();
  }

  Future<void> _clearSessionCookie() async {
    final base = baseUrl;
    if (base == null) return;
    try {
      await (_persistentJar ?? api?.cookieJar)?.delete(Uri.parse(base));
    } catch (_) {}
  }

  /// cookie 持久化(应用支持目录);测试环境无插件通道 → 内存 jar 兜底。
  Future<void> initPersistence() async {
    if (_persistentJar != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _cookieDirPath = '${dir.path}/.cookies';
      _persistentJar =
          PersistCookieJar(storage: FileStorage(_cookieDirPath!));
    } catch (e) {
      // R4b:失败不再静默——插件通道失败是「重启要求重登」的候选根因之一,
      // 留日志(降级语义不变:走内存 jar)。
      _persistentJar = null; // 走内存 jar
      _cookieDirPath = null;
      AppLog.error('session', 'cookie 持久化初始化失败,降级内存 jar(重启需重登)', e);
    }
  }

  void _setPhase(SessionPhase p) {
    phase = p;
    notifyListeners();
  }
}

/// 全局单例(页面经 [session] 取 api/me;不引状态管理框架)。
final session = Session();
