/// PreviewPermissions — 预览页(搜索入口)逐素材下载权解析:canDownload=null
/// 时按当前素材的 folderId 经单夹详情 my_can_download 补水;同一夹只请求一次
/// (成功/失败都落缓存,失败落 null 不重试),解析完成 notifyListeners 由页面
/// 重建。另承载逐素材 folderId / 展示路径映射读取。
///
/// 只持有解析所需的值(不依赖路由参数 PreviewArgs),避免与预览页循环 import。
library;

import 'package:flutter/foundation.dart';

import '../../core/session.dart';
import '../../models/models.dart';

/// 下载权三态:页面级可信值(宫格入口)优先,否则按素材所属夹缓存取值。
class PreviewPermissions extends ChangeNotifier {
  PreviewPermissions({
    required this.folderIds,
    required this.wheres,
    required this.folderId,
    required this.where,
    required this.canDownload,
  });

  /// 逐素材 folderId(asset.id → folderId);null=整组沿用 [folderId]。
  final Map<String, String>? folderIds;

  /// 逐素材展示路径(asset.id → where);null=整组沿用 [where]。
  final Map<String, String>? wheres;

  /// 页面级 folderId(逐素材缺省时回退)。
  final String folderId;

  /// 页面级展示路径(逐素材缺省时回退)。
  final String? where;

  /// 页面级下载权(bool=可信值,宫格入口);null=按素材所属夹解析。
  final bool? canDownload;

  /// 按 folderId 缓存的下载权:true/false=已解析;null=详情失败/缺值(未知)。
  final _folderCanDownload = <String, bool?>{};

  /// 正在请求的 folderId(防同一夹并发重复请求)。
  final _resolvingFolders = <String>{};

  var _disposed = false;

  /// 当前素材的 folderId / 展示路径(逐素材映射优先,旧入口回退页面级值)。
  String folderIdOf(Asset a) => folderIds?[a.id] ?? folderId;
  String? whereOf(Asset a) => wheres?[a.id] ?? where;

  /// 当前素材的下载权:页面级可信值(宫格入口)优先,否则取所属夹缓存。
  bool? canDownloadFor(Asset a) =>
      canDownload ?? _folderCanDownload[folderIdOf(a)];

  /// P1-3 + 跨文件夹 P1:canDownload=null 时按当前素材的 folderId 用单夹详情
  /// my_can_download 补水;同一夹只解析一次(成功/失败都落缓存),失败静默。
  Future<void> ensure(Asset a) async {
    if (canDownload != null) return; // 宫格入口沿用页面级三态
    final fid = folderIdOf(a);
    if (fid.isEmpty ||
        _folderCanDownload.containsKey(fid) ||
        !_resolvingFolders.add(fid)) {
      return;
    }
    final api = session.api;
    if (api == null) {
      _resolvingFolders.remove(fid);
      return;
    }
    try {
      final folder = await api.folders.get(fid);
      _folderCanDownload[fid] = folder.myCanDownload;
    } catch (_) {
      // 静默:详情失败落未知(null),申请入口不亮,下载按未知放行
      _folderCanDownload[fid] = null;
    } finally {
      _resolvingFolders.remove(fid);
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
