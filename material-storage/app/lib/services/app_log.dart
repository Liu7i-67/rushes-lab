/// AppLog — 全量本地持久日志(移动端 debug 不便:console 看不到、连不上 Xcode)。
///
/// 捕获面:
///   1. 主动埋点:AppLog.info/error(登录/上传/下载/相册等关键动作,见各调用点)
///   2. dio 拦截器(ms_api.dart 构造时挂入):每个请求的方向/状态码/错误
///   3. 兜底:FlutterError.onError + PlatformDispatcher.onError(未捕获异常)
/// 存储:应用文档目录 app.log,逐行追加;超 2MB 截头保尾(留 1MB);
/// 推送前再兜底一次:超 10MB 截尾保最近一半(企微 upload_media 硬限 20MB,
/// 长期不重启时 init 的冷启动轮转不会触发);
/// 一键经 WeComPush 推企业微信,成功后 clear()。
library;

import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError, debugPrint;
import 'package:path_provider/path_provider.dart';

class AppLog {
  AppLog._();

  static File? _file;
  static bool _initialized = false;
  static int _lines = 0;
  // 文件就绪前的日志先进内存,init 完成后一次性补写(「所有的」不丢)
  static final List<String> _pending = [];

  static const int _maxFileBytes = 2 * 1024 * 1024;

  /// 推送前上限:企业微信 upload_media 限 20MB,留一半余量防编码/表单膨胀。
  static const int pushMaxBytes = 10 * 1024 * 1024;

  /// 幂等初始化;测试环境(无插件通道)静默降级为仅内存/控制台。
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 3. 框架/未捕获异常兜底(保留 debug 期控制台原始呈现)
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log('ERROR', 'flutter', details.toStringShort());
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      error('zone', '未捕获异常', e);
      return true;
    };

    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/app.log');
      if (!await _file!.exists()) {
        await _file!.create(recursive: true);
      } else if (await _file!.length() > _maxFileBytes) {
        // 轮转:超限截头保尾 1MB
        final keepFrom = await _file!.length() - _maxFileBytes ~/ 2;
        final bytes = await _file!
            .openRead(keepFrom)
            .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        await _file!.writeAsBytes(bytes, flush: true);
        info('log', '历史日志超 2MB 已截断');
      }
      if (_pending.isNotEmpty) {
        await _file!.writeAsString(
          '${_pending.join('\n')}\n',
          mode: FileMode.append,
        );
        _pending.clear();
      }
      _lines = await _file!.readAsLines().then((l) => l.length);
      info('log', 'AppLog 就绪(file=${_file!.path})');
    } catch (_) {
      // 无文件系统/插件通道(单测):仅内存
    }
  }

  static void info(String tag, String msg) => log('INFO', tag, msg);

  static void error(String tag, String msg, [Object? e]) =>
      log('ERROR', tag, e == null ? msg : '$msg: $e');

  /// 单条写:文件就绪则追加,否则入 pending;控制台同步。
  static void log(String level, String tag, String msg) {
    final line = '${DateTime.now().toIso8601String()} [$level] [$tag] $msg';
    _lines++;
    debugPrint('[AppLog] $line');
    final f = _file;
    if (f != null) {
      // 追加失败(磁盘满等)不阻断业务
      f.writeAsString('$line\n', mode: FileMode.append, flush: true).ignore();
    } else {
      _pending.add(line);
    }
  }

  /// 取日志文件(空日志写占位行,企业微信拒绝空文件)。
  ///
  /// 推送前防御截尾:Android 有传输前台服务,App 可能长期不重启,init 的
  /// 轮转只在冷启动执行;错误风暴下文件可涨过企微 20MB 硬限,导致推送
  /// 永久失败(重试也不会缩小文件)。超 [maxBytes](默认 [pushMaxBytes])时
  /// 截尾保最近一半,keepFrom 对齐到行首(跳过被切开的半行),与 init
  /// 轮转「超限留一半」语义一致。[maxBytes] 仅供单测注入小阈值。
  static Future<File> dumpFile({int? maxBytes}) async {
    final f = _file ?? File('${Directory.systemTemp.path}/app.log');
    if (_file == null) {
      await f.writeAsString('(无持久化存储,内存日志不可用)\n');
      return f;
    }
    if (await f.length() == 0) {
      await f.writeAsString(
        '${DateTime.now().toIso8601String()} [INFO] [log] (空日志占位)\n',
      );
    }
    final limit = maxBytes ?? pushMaxBytes;
    final length = await f.length();
    if (length > limit) {
      // 只读尾部(文件可达数十 MB),再按行首对齐,避免首行半截
      final keepFrom = length - limit ~/ 2;
      final bytes = await f
          .openRead(keepFrom)
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      final nl = bytes.indexOf(0x0A);
      final tail = nl == -1 ? bytes : bytes.sublist(nl + 1);
      await f.writeAsBytes(tail, flush: true);
      info('log', '推送前日志超 ${(limit / 1024 / 1024).toStringAsFixed(0)}MB 已截断');
    }
    return f;
  }

  static Future<({int lines, int bytes})> stats() async {
    final f = _file;
    if (f == null || !await f.exists()) return (lines: _lines, bytes: 0);
    return (lines: _lines, bytes: await f.length());
  }

  /// 推送成功后调用:清空文件与计数。
  static Future<void> clear() async {
    _lines = 0;
    final f = _file;
    if (f != null && await f.exists()) {
      await f.writeAsString('', flush: true);
    }
  }
}
