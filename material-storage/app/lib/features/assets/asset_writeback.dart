/// 素材写操作成功后的统一失效口径(B5 功能点 5,方案 §8.1 数据新鲜度):
/// 删除/移动/打标/前缀/恢复成功 → invalidate `assets:<folderId>`(宫格静默刷新)
/// + `folders`(子树计数)。与上传侧 notifyUploadSuccess(upload_sheet.dart)同构。
library;

import '../../core/refresh_bus.dart';

void notifyAssetMutation(String folderId) {
  RefreshBus.I.invalidate('assets:$folderId');
  RefreshBus.I.invalidate('folders');
}
