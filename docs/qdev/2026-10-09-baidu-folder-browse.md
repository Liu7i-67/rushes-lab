# 百度网盘目录浏览：文件可见 — 需求文档

日期：2026-10-09 ｜ 流程：qdev ｜ 状态：定稿
分支：`feat/baidu-folder-browse`（基于 `fix/baidu-import-key-conflict` `a6dfe79`，worktree 复用 `rushes-lab-fix-baidu-import-key-conflict`）

## 背景与根因

007 在 hh2 dev 新建备份任务时反馈：网盘目录树「仅显示根目录的文件夹，没显示根目录的文件；点击文件夹也看不到其中的文件和子文件夹」。

**排查结论（dev 日志+接口实测）**：非故障、非限流——007 会话中 `/backup/netdisk/folders` 全部返回 200，现在实测子目录列举也正常（`/备份测试`→`[二级目录]`）。真实原因是产品差距：该接口为「目录选择器」设计，`list_dir(folders_only=True)` 只返回文件夹（`folder=1`）——

1. 根目录的文件被设计排除（用户看不到）；
2. 纯文件目录（如 `/灵机备份`：1 png + 1 mp4，无子夹）展开返回空列表 → 用户感知为「点不开」。

用户期望：浏览时能看到目录内的**文件和子文件夹**（像网盘客户端）。

## 功能点明细（验收级）

- **F1 目录浏览返回全条目**：`GET /api/v1/baidu/backup/netdisk/folders?path=` 改为返回该目录的子文件夹 + 文件（xpan `method=list`，`folder=0`），懒加载语义不变（每次展开一次调用）。
  - 条目含：`path`（文件为父目录+文件名拼成的完整路径）、`name`、`is_dir: bool`、`size_bytes: int | None`（目录为 None）。
  - 排序：目录在前、文件在后，各组内按名称（后端排序，前端不再排）。
  - truncated 语义不变（>max_pages 聚合未取尽置 true）。
  - 60s Redis 缓存 key/TTL 不变（部署后旧缓存自然过期）。
- **F2 前端树渲染文件行**：目录树中文件行显示文件图标 + 名称 + 人类可读大小，**灰显不可选**（`selectable: false`，保持「选目录创建任务」语义）；目录行照常可选可展开。
  - loadData 失败时**不再吞错返回 []**（会把错误伪装成空目录）——保持 toast 报错、节点维持可重试展开状态。
  - truncated=true 时在展开的子节点列表尾部插入一个不可选的提示行「目录过大，仅显示部分内容」。
  - 「已选来源」与创建任务逻辑零改动（文件不可选，sourceDir 恒为目录）。
- **F3 类型与契约**：`BaiduNetdiskFolder`（前端 types.ts）增 `is_dir`/`size_bytes`；响应模型 `BaiduNetdiskFolderOut` 同步；端点路径/入参不变。

## 数据库修改方案

不涉及。

## 接口定义

| 方法+路径 | 变更 | 入参 | 返回 | 错误码 |
| --- | --- | --- | --- | --- |
| `GET /backup/netdisk/folders` | 返回条目由「仅目录」变「目录+文件」，条目结构扩展 | `path`（不变） | `BaiduNetdiskFoldersOut{ list: [{path, name, is_dir, size_bytes}], truncated }` | 沿用（400 path/409 binding_inactive/百度错误映射） |

注意（口径更正，专职测试复核）：xpan list 文件条目的 `path` 字段实测为**完整路径**（与枚举侧口径一致，经 007 真实导入验证：枚举 source_path 直接取 item path 且嵌套 rel_path 正确）。浏览侧实现采用 `dir_path.rstrip('/') + '/' + server_filename` 拼接——与该值等价，但显式自证、不依赖该字段。目录条目的 `path` 是完整路径（现状口径）。字段参照调研脚本 `scripts/task/baidu_file_list.py`（列表行含 `isdir`(0/1)、`server_filename`、`size`）。

## 前端改动点（`material-storage/web/`）

- `api/types.ts`：`BaiduNetdiskFolder` 增 `is_dir: boolean; size_bytes: number | null`。
- `components/BaiduNewTaskModal.tsx`：`toNetdiskNode` 按条目分派（目录=现状；文件=文件图标+大小+`isLeaf:true`+`selectable:false`+灰显样式）；loadData 失败 re-throw；truncated 尾插提示行；大小人类可读（复用仓内已有 bytes 格式化 helper，若有）。
- `lib/labels.ts`：如需「目录过大」提示文案映射则补。

## 后端改动点（`material-storage/api/`）

- `routers/baidu_backup.py` `list_netdisk_folders`：`folders_only=False`；条目解析目录/文件两态（isdir 判定、文件名取 `server_filename`、size 取 `size`）；排序目录前文件后（各按 name）；缓存内容随之变全条目。
- `models`（`app/models/__init__.py`）：`BaiduNetdiskFolderOut` 增 `is_dir: bool`、`size_bytes: int | None = None`。
- `services/baidu_client.py`：不改（`folders_only` 参数已支持 False）。

## 测试功能点（集成为主）

1. 〔集成〕mock list 返回混合条目（目录+文件）→ 端点返回两态条目：文件 `is_dir=false`、`size_bytes` 正确、`path`=父目录+文件名完整拼接；目录 `is_dir=true`、`size_bytes=null`。
2. 〔集成〕纯文件目录 → 非空列表（原「点开为空」场景直拍）。
3. 〔集成〕排序：目录在前文件在后、组内名称序。
4. 〔集成〕truncated=true 透传。
5. 〔集成〕缓存命中返回全条目（第二次同 path 走缓存且条目完整）。
6. 〔集成〕回归：既有 folders 相关用例（若断言 folder=1 传参/仅目录语义需同步更新）；binding_inactive/400 path 校验不变。
7. 前端：build+lint；（静态）文件行 selectable:false、loadData 不吞错。

## 模糊点与决策记录

- **D1（PM，问询未获答复按推荐执行）**：数据通道用逐目录懒加载 `list`（folder=0），不用 listall 递归——懒加载天然匹配、调用量与现状相同（测试态频控友好）、大目录由既有聚合分页+truncated 护栏。listall 的正确用途是任务枚举加速（另行评估，非本轮）。
- **D2（PM，同上）**：文件行仅展示不可选——保持目录选择语义；文件行显示名称+大小+图标灰显。
- **D3（PM）**：loadData 失败从「收口空目录」改为「报错+可重试展开」——错误不再伪装成空目录。
- **D4（PM）**：排序后端做（目录前/文件后/组内名称序），前端直接渲染。

## 部署注意

无 migration、无 .env 变更；代码+SPA 常规通道（先代码重启后 SPA）。
