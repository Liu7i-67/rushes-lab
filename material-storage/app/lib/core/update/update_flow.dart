/// AppUpdateFlow — 更新流程编排(F2-4/5/6):启动自动检查(静默)与手动
/// 检查(SnackBar 反馈)共用「确认弹窗 → 下载进度 → 调起安装」链路。
///
/// session 级语义:
/// - 自动检查仅 Android、首帧后约 3s、每 session 至多弹一次(D9);
/// - 确认弹窗一旦弹出(无论确认/取消),本 session 不再自动弹(T6/D5);
/// - 自动检查任何失败(网络/超时/解析)完全静默,无 toast 无弹窗无日志(T5)。
///
/// 可测缝(T4/T5/T6):[isAndroid] 显式入参(不内部摸 Platform)、
/// [delay] 可置零、service/updater/localVersion 均可注入、
/// [autoPromptUsed] 可判定。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../session.dart';
import 'apk_updater.dart';
import 'app_version_info.dart';
import 'update_dialogs.dart';
import 'update_errors.dart';
import 'update_service.dart';
import 'version_compare.dart';

/// 本地版本(version=x.y.z,build=n;build 解析失败兜底 0)。
typedef LocalAppVersion = ({int build, String version});

/// 「我的」页展示口径:x.y.z+n(全平台,F2-1)。
String localVersionLabel(LocalAppVersion v) => '${v.version}+${v.build}';

Future<LocalAppVersion> _readLocalVersion() async {
  final p = await PackageInfo.fromPlatform();
  return (
    version: p.version,
    build: int.tryParse(p.buildNumber) ?? 0,
  );
}

/// 全局单例(main.dart 挂自动检查,me 页挂手动入口;与 session/maintenanceBanner
/// 同款模块级装配风格)。
final appUpdate = AppUpdateFlow();

class AppUpdateFlow {
  AppUpdateFlow({
    UpdateService? service,
    ApkUpdater? updater,
    Future<LocalAppVersion> Function()? localVersion,
  })  : _service = service ?? UpdateService(),
        _updater = updater ?? ApkUpdater(),
        _localVersion = localVersion ?? _readLocalVersion;

  final UpdateService _service;
  final ApkUpdater _updater;
  final Future<LocalAppVersion> Function() _localVersion;

  /// T6 判定缝:确认弹窗本 session 是否已弹出过(弹过即不再自动弹)。
  @visibleForTesting
  bool get autoPromptUsed => _autoPromptUsed;

  bool _autoPromptUsed = false;

  /// 读取本地版本(「我的」页版本行用;注入缝 [_localVersion] 的透出)。
  Future<LocalAppVersion> currentVersion() => _localVersion();

  /// F2-4 启动自动检查:仅 [isAndroid];[delay](默认 3s,首帧后由调用方经
  /// addPostFrameCallback 触发)后执行一次;发现新版本弹确认弹窗。
  /// 任何失败静默返回;导航未就绪同样放弃(本 session 不再自动弹,手动入口不受影响)。
  Future<void> autoCheckOnce({
    required bool isAndroid,
    Duration delay = const Duration(seconds: 3),
  }) async {
    if (!isAndroid || _autoPromptUsed) return;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (_autoPromptUsed) return; // delay 期间手动入口已弹过
    final LocalAppVersion local;
    final AppVersionInfo info;
    try {
      local = await _localVersion();
      info = await _service.fetchLatest();
    } catch (_) {
      return; // T5:完全静默
    }
    if (!isNewerVersion(
      remoteVersion: info.version,
      remoteBuild: info.build,
      localVersion: local.version,
      localBuild: local.build,
    )) {
      return;
    }
    // 即将弹窗:一次性闸门此刻用掉(T6)——取消/导航未就绪都不再自动弹
    _autoPromptUsed = true;
    final nav = session.navigatorKey.currentState;
    if (nav == null || !nav.mounted) return;
    await promptUpdate(nav.context, info: info, currentVersion: local);
  }

  /// F2-6 手动检查(F2-1「检查更新」入口):已是最新 → SnackBar;失败 →
  /// SnackBar 可读错误;有新版 → 确认弹窗(同样消费自动弹窗闸门)。
  Future<void> manualCheck(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final LocalAppVersion local;
    final AppVersionInfo info;
    try {
      local = await _localVersion();
      info = await _service.fetchLatest();
    } on UpdateException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on FormatException {
      messenger?.showSnackBar(
          const SnackBar(content: Text('暂无有效更新信息,请稍后再试')));
      return;
    } catch (_) {
      messenger?.showSnackBar(
          const SnackBar(content: Text('检查更新失败,请稍后重试')));
      return;
    }
    if (!isNewerVersion(
      remoteVersion: info.version,
      remoteBuild: info.build,
      localVersion: local.version,
      localBuild: local.build,
    )) {
      messenger?.showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
      return;
    }
    if (!context.mounted) return;
    await promptUpdate(context, info: info, currentVersion: local);
  }

  /// 确认弹窗(F2-5)→ 确认后进入下载安装。弹出即消费自动闸门(D5/T6)。
  Future<void> promptUpdate(
    BuildContext context, {
    required AppVersionInfo info,
    required LocalAppVersion currentVersion,
  }) async {
    _autoPromptUsed = true;
    final confirmed = await showUpdateConfirmDialog(context, info: info);
    if (!confirmed) return; // 取消:关闭即可,本 session 不再自动弹
    if (!context.mounted) return;
    await downloadAndInstall(context, info: info);
  }

  /// 下载(F2-6):进度弹窗(可取消)→ 下载到临时目录 → 关弹窗 → 调起安装;
  /// 取消/失败清理半成品(ApkUpdater 内),失败 SnackBar 可读错误。
  Future<void> downloadAndInstall(
    BuildContext context, {
    required AppVersionInfo info,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final cancelToken = CancelToken();
    final progress = ValueNotifier<int>(0);
    var dialogOpen = false;
    void closeDialog() {
      if (!dialogOpen) return;
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }

    final String savePath;
    try {
      savePath = await _updater.tempApkPath(info.version);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text(
            e is UpdateException ? e.message : '下载准备失败,请稍后重试'),
      ));
      return;
    }
    if (!context.mounted) return;
    dialogOpen = true;
    final dialogFuture = showUpdateProgressDialog(
      context,
      progress: progress,
      onCancel: () {
        cancelToken.cancel();
        closeDialog();
      },
    );
    try {
      await _updater.download(
        url: info.androidUrl,
        savePath: savePath,
        cancelToken: cancelToken,
        onProgress: (p) => progress.value = p,
      );
      closeDialog();
    } on UpdateException catch (e) {
      closeDialog();
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } finally {
      await dialogFuture; // 等弹窗退场完成再释放进度通知器
      progress.dispose();
    }
    if (cancelToken.isCancelled) return; // 用户取消:半成品已清理,静默收场
    try {
      await _updater.install(savePath);
    } on UpdateException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
