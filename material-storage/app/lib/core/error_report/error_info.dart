/// ErrorInfo — 全局报错页展示与复制的错误快照(纯数据,不依赖 UI)。
///
/// 产生点见同目录 error_report_controller.dart:接口 5xx / 网络传输层异常 /
/// 框架未捕获异常统一收敛成本模型,页面只负责渲染与复制。
/// 设计取舍:不可变(const 构造 + final 字段)——报错页展示期间错误不会再被
/// 修改,避免页面读到半更新状态;time 取捕获点的 DateTime.now() 而非展示
/// 时刻,保证复制出的报告与真实发生时间一致。
library;

/// 错误大类(页面「类型」行与复制报告共用)。
enum ErrorKind { api, system }

class ErrorInfo {
  const ErrorInfo({
    required this.kind,
    required this.time,
    required this.source,
    this.status,
    required this.message,
    this.stackText,
  });

  final ErrorKind kind;
  final DateTime time;

  /// 来源标识:接口类为 `METHOD path`(如 `GET /api/v1/projects`),
  /// 系统类为 `flutter` / `zone` / `render`。
  final String source;

  /// HTTP 状态码(仅接口类可能非空;网络异常通常为 null)。
  final int? status;

  /// 用户可读详情(ApiException.message / DioException 文案 / 异常 toString)。
  final String message;

  /// 堆栈全文(系统异常有;接口异常通常为 null)。
  final String? stackText;

  String get kindLabel => kind == ErrorKind.api ? '接口异常' : '系统异常';

  /// 复制到剪贴板的报告全文:时间/类型/来源/状态码/详情/堆栈逐段呈现,
  /// 便于用户直接粘给开发定位(status/stack 缺失时省略对应段)。
  String toClipboardText() {
    final b = StringBuffer()
      ..writeln('【浣花视界 App 错误报告】')
      ..writeln('时间：${_fmtTime(time)}')
      ..writeln('类型：$kindLabel')
      ..writeln('来源：$source');
    if (status != null) b.writeln('状态码：$status');
    b.writeln('详情：$message');
    final stack = stackText?.trim();
    if (stack != null && stack.isNotEmpty) {
      b
        ..writeln('堆栈：')
        ..write(stack);
    }
    return b.toString().trimRight();
  }
}

/// 本地时区 YYYY-MM-DD HH:mm:ss(报告需能跨时区核对,秒级足够)。
String _fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
