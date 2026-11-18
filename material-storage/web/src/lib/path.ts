/**
 * 网盘目录末段派生单一正本(P2-2:四处重复收敛于此,消费方一律 import)。
 * 口径出处:需求文档 docs/qdev/2026-11-18-baidu-backup-same-name-folder.md §8 / UC-09,
 * 与 App 端 baidu_task.dart `_leafOf` 同口径:先 rstrip('/') 再取 lastIndexOf('/') 末段。
 */

/** 网盘目录末段(承接夹命名/展示口径):先去尾斜杠再取末段;整盘根「/」与空串返回空串。 */
export function sourceLeafName(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

/**
 * 同名夹展示后缀(§8 口径):开关开 ∧ 有显式目标夹 ∧ 夹未删(folderName 非空)→ `/末段名`,否则 ''。
 * UC-09 防御:末段为空(source_dir 异常为整盘根「/」)不加后缀,避免悬挂「/「」」。
 */
export function sameNameSuffix(opts: {
  enabled: boolean;
  folderName: string | null | undefined;
  sourceDir: string;
}): string {
  const leaf = sourceLeafName(opts.sourceDir);
  return opts.enabled && opts.folderName && leaf ? `/${leaf}` : '';
}
