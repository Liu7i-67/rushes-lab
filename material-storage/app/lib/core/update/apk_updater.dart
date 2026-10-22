/// ApkUpdater — APK 下载与调起安装(F2-6):
/// - 下载到临时目录 `huanhuashijie-update-<version>.apk`,开始前删同名旧文件(T7);
/// - CancelToken 可取消;取消/失败清理半成品(T7);
/// - 完成后 OpenFilex 调系统安装器(type=application/vnd.android.package-archive),
///   调起失败抛可读 [UpdateException]。
/// 下载用独立裸 Dio(无 cookie/鉴权拦截器;直链公有读),与检查实例分开装配,
/// 接收超时放宽到 60s(APK 大文件按 chunk 计时,防弱网误杀)。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'update_errors.dart';

/// 调起安装的可注入缝(单测不触 OpenFilex 平台通道):done=false 时 message
/// 为可读原因。默认实现包 OpenFilex.open + apk MIME。
typedef ApkOpener = Future<({bool done, String message})> Function(String path);

Future<({bool done, String message})> _openViaFilex(String path) async {
  final r = await OpenFilex.open(
    path,
    type: 'application/vnd.android.package-archive',
  );
  return (done: r.type == ResultType.done, message: r.message);
}

class ApkUpdater {
  ApkUpdater({
    Dio? dio,
    Future<String> Function()? tempDirPath,
    ApkOpener? openApk,
  })  : _dio = dio ?? _buildDio(),
        _tempDirPath = tempDirPath ?? _defaultTempDir,
        _openApk = openApk ?? _openViaFilex;

  static Dio _buildDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 60),
      ));

  static Future<String> _defaultTempDir() async {
    final dir = await getTemporaryDirectory();
    return dir.path;
  }

  final Dio _dio;
  final Future<String> Function() _tempDirPath;
  final ApkOpener _openApk;

  /// 临时目录(app 支持缓存区;注入缝供单测用内存/临时目录替代)。
  Future<String> _resolveTempDir() => _tempDirPath();

  /// APK 落盘路径:`{tmp}/huanhuashijie-update-<version>.apk`(F2-6)。
  Future<String> tempApkPath(String version) async {
    final dir = await _resolveTempDir();
    // 不引 path 包(新依赖白名单外);Android/iOS 临时目录均为 '/' 分隔
    return dir.endsWith('/')
        ? '$dir${_apkFileName(version)}'
        : '$dir/${_apkFileName(version)}';
  }

  static String _apkFileName(String version) =>
      'huanhuashijie-update-$version.apk';

  /// 下载 APK 到 [savePath]。进度回调 percent ∈ 0..100,总长未知传 -1
  /// (UI 落进行中态)。用户取消:清理半成品后正常返回(调用方以
  /// `cancelToken.isCancelled` 分流);失败:清理半成品并抛 [UpdateException]。
  Future<void> download({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    required void Function(int percent) onProgress,
  }) async {
    final file = File(savePath);
    // 开始前删同名旧文件(T7):防半成品/旧版本残留被误当完整包
    if (await file.exists()) {
      await file.delete();
    }
    try {
      await _dio.download(
        url,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          onProgress(total > 0
              ? (received * 100 / total).floor().clamp(0, 100)
              : -1);
        },
      );
    } on DioException catch (e) {
      await _safeDelete(file);
      if (CancelToken.isCancel(e)) return; // 取消:不算错误,半成品已清理
      throw UpdateException(describeDioError(e));
    } catch (e) {
      await _safeDelete(file);
      throw UpdateException('下载失败,请稍后重试($e)');
    }
  }

  /// 调系统安装器;调起失败抛可读错误(F2-6:「允许安装未知应用」等引导
  /// 交真机清单,这里只把 OpenFilex 的 message 透出)。
  Future<void> install(String savePath) async {
    final r = await _openApk(savePath);
    if (!r.done) {
      throw UpdateException('无法启动安装:${r.message}');
    }
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 清理失败不影响主流程(临时目录,系统可回收)
    }
  }
}
