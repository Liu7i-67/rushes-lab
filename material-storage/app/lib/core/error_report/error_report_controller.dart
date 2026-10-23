/// ErrorReportController — 全局错误上报编排:门槛判定 → 防套娃/冷却窗 →
/// 帧后调度跳转报错页。
///
/// 数据来源三路(见方案「数据流」):
///   1. MsApi.err() 5xx → [onApiError](Session 装配 MsApi 时挂钩)
///   2. 主 Dio 传输层异常(非 badResponse)→ [onNetworkError](同处挂钩)
///   3. FlutterError / PlatformDispatcher / ErrorWidget.builder → [onSystemError]
///
/// 设计要点(方案「实现钉子」):
///   · 所有路径先 AppLog.error 留痕,保证「推送日志」必含该错误;
///   · 跳转一律 addPostFrameCallback 调度——框架异常可能在 build/layout 期
///     触发,同步 push 会抛 setState() called during build;
///   · 链式钩子转发 previous,不吞 AppLog 既有兜底;
///   · 在页/冷却/帧回调挂起期间的上报只记日志,防连环弹窗。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../../services/app_log.dart';
import '../api/ms_api.dart';
import '../session.dart';
import 'error_info.dart';

/// 全局单例(main 装配、core 各钩子与页面共用;不引状态管理框架)。
final errorReporter = ErrorReportController();

class ErrorReportController {
  /// 报错页路由名(包 B 在 app.dart onGenerateRoute 注册;arguments=ErrorInfo)。
  static const String _routeName = '/error-report';

  /// 关闭报错页后的冷却时长(D6:轮询接口连环失败时防「关了又弹」)。
  static const Duration _cooldownWindow = Duration(seconds: 3);

  /// 当前待展示/已展示的错误(push 前必 set;页面读后可置 null)。
  ErrorInfo? currentError;

  bool _installed = false;
  bool _debugFrameworkJump = kDebugMode;
  bool _onPage = false;
  bool _pushScheduled = false;
  Timer? _cooldown;

  /// main() 调一次;重复调用只更新 [debugFrameworkJump],不重复挂钩。
  /// [debugFrameworkJump] 缺省随 kDebugMode:D5 要求框架系统错误仅 release
  /// 跳转(debug 期 overflow/图片解码噪声多),测试可注入翻转验证。
  void install({bool debugFrameworkJump = kDebugMode}) {
    _debugFrameworkJump = debugFrameworkJump;
    if (_installed) return;
    _installed = true;
    // 链式包裹而非替换:AppLog.init 已挂过兜底,previous 必须继续被执行
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      onSystemError(details.exception, details.stack, 'flutter');
      previousFlutter?.call(details);
    };
    final previousZone = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      onSystemError(error, stack, 'zone');
      return previousZone?.call(error, stack) ?? true;
    };
  }

  /// MsApi.err() 钩子:仅 5xx/未知状态码进入跳转候选(D1);4xx 保持就地
  /// toast,401 仍走既有 onSessionExpired 跳登录链路。method/path 缺省时取
  /// ApiException 携带的请求上下文(全局钩子单参形式传不到)。
  void onApiError(ApiException e, {String? method, String? path}) {
    final source = _source(method ?? e.method, path ?? e.path, fallback: 'api');
    AppLog.error('error_report', '接口异常 status=${e.status} 来源=$source', e);
    final s = e.status;
    if (s != null && s < 500) return;
    _report(ErrorInfo(
      kind: ErrorKind.api,
      time: DateTime.now(),
      source: source,
      status: s,
      message: e.message,
    ));
  }

  /// 主 Dio onError 钩子(非 badResponse 型才到达):超时/断网/证书等传输层
  /// 异常全数进入跳转候选(D1)。badResponse 在 MsApi 层已被 validateStatus
  /// 全放行消解,此处仍防御性忽略,避免同一错误双重上报(实现钉子 6)。
  void onNetworkError(DioException e, {String? method, String? path}) {
    // 取消是调用方的正常业务动作(搜索防抖换词 search_page / 传输任务取消
    // transfer_queue 都主动 cancel),不是错误:不记 error 日志、不跳转。
    // 拦截器已排除,此处防御性第二道,防其他接入点漏判。
    if (e.type == DioExceptionType.cancel) return;
    final source = _source(
      method ?? e.requestOptions.method,
      path ?? e.requestOptions.uri.path,
      fallback: 'network',
    );
    AppLog.error('error_report', '网络异常 ${e.type.name} 来源=$source', e);
    if (e.type == DioExceptionType.badResponse) return;
    _report(ErrorInfo(
      kind: ErrorKind.api,
      time: DateTime.now(),
      source: source,
      status: e.response?.statusCode,
      message: _networkMessage(e),
    ));
  }

  /// 框架异常钩子(FlutterError / zone / 渲染异常):D5 分流——debug 期只留
  /// 日志(噪声多),release 才跳报错页;API 路径不受此开关影响。
  void onSystemError(Object error, StackTrace? stack, String source) {
    AppLog.error('error_report', '系统异常[$source]', error);
    if (_debugFrameworkJump) return;
    _report(ErrorInfo(
      kind: ErrorKind.system,
      time: DateTime.now(),
      source: source,
      message: '$error',
      stackText: stack?.toString(),
    ));
  }

  /// 报错页生命周期钩子:initState(true) 期间一切上报只记日志(D2);
  /// dispose(false) 起开 3s 冷却窗(D6)。重入页面时清掉残余冷却计时器。
  void markOnPage(bool onPage) {
    _onPage = onPage;
    // 帧回调执行 push 后到页面 initState 置位前是一个窗口期:_pushScheduled
    // 必须跨帧保持,窗口内第二路错误才会被 _report 忽略、currentError 保持
    // 首条(D2);直到页面 initState 确认(此处)才复位,允许关闭后再次上报。
    if (onPage) _pushScheduled = false;
    _cooldown?.cancel();
    _cooldown = null;
    if (!onPage) {
      _cooldown = Timer(_cooldownWindow, () => _cooldown = null);
    }
  }

  /// 测试复位(生产不调用):清页面态/冷却计时器/待跳转标记,并允许下一次
  /// install 重新链式挂钩(各用例需独立验证 previous 转发)。
  @visibleForTesting
  void reset() {
    currentError = null;
    _onPage = false;
    _pushScheduled = false;
    _cooldown?.cancel();
    _cooldown = null;
    _installed = false;
    _debugFrameworkJump = kDebugMode;
  }

  /// 统一落点:门槛已过,再按 在页(D2)/冷却(D6)/帧回调挂起(钉子 1) 拦截;
  /// 通过则记下 currentError 并调度下一帧 push(绝不在此同步导航)。
  void _report(ErrorInfo info) {
    if (_onPage || _cooldown != null || _pushScheduled) {
      AppLog.info(
        'error_report',
        '忽略上报(在页=$_onPage 冷却=${_cooldown != null} '
            '待跳转=$_pushScheduled):${info.source}',
      );
      return;
    }
    currentError = info;
    _pushScheduled = true;
    try {
      final binding = WidgetsBinding.instance;
      // 帧后回调只在下一帧执行,而 addPostFrameCallback 本身不请求新帧:
      // 空闲期(无动画)必须显式 scheduleFrame,否则跳转要等下一次 UI 变动
      binding.addPostFrameCallback((_) {
        // 此处不复位 _pushScheduled:push 后新页要下一帧 build 才 markOnPage
        // (true),窗口内的后续错误必须继续被忽略(D2 首条语义),复位交给
        // 页面 initState;仅跳转兜底分支复位,防永久卡死。
        final nav = session.navigatorKey.currentState;
        if (nav == null) {
          // 极早期(navigator 尚未挂载)只留日志,不抛(方案契约)
          _pushScheduled = false;
          AppLog.error(
              'error_report', 'navigator 未就绪，错误未能跳转', info.message);
          return;
        }
        try {
          unawaited(nav.pushNamed<void>(_routeName, arguments: info).catchError(
            (Object e) {
              // 路由未注册等异步失败:页面不会 initState,需复位防卡死
              _pushScheduled = false;
              AppLog.error('error_report', '报错页跳转失败', e);
            },
          ));
        } catch (e) {
          // 路由未注册(debug assert)等同步异常兜底,避免冒泡成新的系统异常
          _pushScheduled = false;
          AppLog.error('error_report', '报错页跳转失败', e);
        }
      });
      binding.scheduleFrame();
    } catch (e) {
      // 界面绑定尚未初始化(纯 Dart 环境/极早期):降级为仅日志
      _pushScheduled = false;
      AppLog.error('error_report', '界面未就绪，错误未能跳转', e);
    }
  }

  /// source 拼 `METHOD path`(有则);均缺失时用 [fallback] 兜底展示。
  String _source(String? method, String? path, {required String fallback}) {
    final m = method?.trim() ?? '';
    final p = path?.trim() ?? '';
    if (m.isEmpty && p.isEmpty) return fallback;
    if (p.isEmpty) return m;
    if (m.isEmpty) return p;
    return '$m $p';
  }

  /// DioException.message 有则透出(测试可注入具体文案);缺失时按类型给
  /// 中文兜底,避免报错页只显示英文传输层描述。
  String _networkMessage(DioException e) {
    final msg = e.message?.trim();
    if (msg != null && msg.isNotEmpty) return msg;
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout =>
        '网络请求超时，请检查网络后重试',
      DioExceptionType.connectionError => '网络连接失败，请检查网络后重试',
      DioExceptionType.badCertificate => '服务器证书校验失败',
      DioExceptionType.cancel => '请求已取消',
      DioExceptionType.badResponse => '服务器返回异常状态码',
      DioExceptionType.unknown => '网络请求失败',
    };
  }
}
