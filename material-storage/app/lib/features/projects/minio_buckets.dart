/// MinIO bucket 选项(新建项目「高级」折叠内)。
///
/// 与 web `NewProjectModal.tsx` 的硬编码 options **同源**:后端没有「可用桶
/// 列表」接口,PoC 部署为单桶 ms-dev。新增/变更桶时**两端必须同步修改**
/// (web 前端硬编码 + 本文件)。
///
/// 2026-10-22(第四批):bucket 由自由输入改为下拉——自由输入会允许填入不存在
/// 的桶名,项目创建成功但首次上传即 500(NoSuchBucket),且项目 bucket 无 API
/// 可改。下拉把可达值收敛到已知桶。
library;

class MinioBucketOption {
  const MinioBucketOption({required this.value, required this.label});
  final String value; // 落库值(minio_bucket)
  final String label; // 展示文案
}

const kMinioBuckets = <MinioBucketOption>[
  MinioBucketOption(value: 'ms-dev', label: 'ms-dev(开发环境)'),
];

/// value → 展示文案(未命中回落 value 本身,兼容历史数据)。
String minioBucketLabel(String value) {
  for (final o in kMinioBuckets) {
    if (o.value == value) return o.label;
  }
  return value;
}
