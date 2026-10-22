/// 「我的」页更新区(F2-1/D6):当前版本号 x.y.z+n 全平台展示;「检查更新」
/// 入口仅 Android(手动检查反馈走 AppUpdateFlow.manualCheck 的 SnackBar)。
/// [isAndroid]/[flow]/[localVersion] 注入供单测(T4 平台 gate)。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/update/update_flow.dart';
import '../../theme/tokens.dart';

class UpdateCheckTile extends StatefulWidget {
  const UpdateCheckTile({
    super.key,
    this.isAndroid,
    this.flow,
    this.localVersion,
  });

  /// 平台 gate 注入(null = 真实判定 `!kIsWeb && Platform.isAndroid`;T4)。
  final bool? isAndroid;

  /// 流程注入(null = 全局 appUpdate 单例)。
  final AppUpdateFlow? flow;

  /// 本地版本来源注入(null = flow 内部 PackageInfo 读取)。
  final Future<LocalAppVersion> Function()? localVersion;

  @override
  State<UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<UpdateCheckTile> {
  AppUpdateFlow get _flow => widget.flow ?? appUpdate;

  /// null = 读取中(显示 …);PackageInfo 通道异常保持 null,不影响页面。
  LocalAppVersion? _local;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final getter = widget.localVersion ?? _flow.currentVersion;
    try {
      final v = await getter();
      if (mounted) setState(() => _local = v);
    } catch (_) {
      // 读不到(如测试环境无插件通道)静默:版本行落 …,入口仍可点
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await _flow.manualCheck(context);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final android = widget.isAndroid ?? (!kIsWeb && Platform.isAndroid);
    final label = _local == null ? '…' : localVersionLabel(_local!);
    if (!android) {
      // iOS/web(D6):仅展示版本,无检查入口
      return ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('当前版本'),
        trailing: Text(label, style: const TextStyle(color: Tk.subtle)),
      );
    }
    return ListTile(
      leading: const Icon(Icons.system_update_outlined),
      title: const Text('检查更新'),
      subtitle: Text('当前版本 $label'),
      trailing: _checking
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: _checking ? null : _check,
    );
  }
}
