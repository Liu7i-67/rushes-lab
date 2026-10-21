# 浣花视界 App 完整版 · B2 浏览线需求文档

> 2026-10-20 · qdev 周期(链式第 1 批)。上位文档=方案 v2.2:
> `rushes-spec/material-storage/mobile-app-full-version-plan.md`(§8.1 浏览/§8.2 预览/
> §11 数据契约/§12 依赖/§9 架构纪律)。
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(分支
> feat/mobile-app-b2-b9,基于 liuqi a98aa43=已含 B0+B1 基建)。

## 范围与交付判据(方案 §16 B2)

项目/文件夹列表(徽标/计数/敏感锁)+ 宫格(缩略图缓存)+ 预览全类型(含视频/livp 播放);
预览页操作钮(下载/分享/申请)本批**占位禁用**,随 B4/B5 点亮。判据:浏览流畅;
预览类型全覆盖(PC 端=analyze+test 全绿;真机留用户终验)。

## 功能点明细

1. **项目列表(§8.1)**:项目行=名称+code+权限徽标(**ROLE_META 同 web**:
   ROLE_RANK(admin>uploader>downloader>viewer)取最高角色主 chip——admin→管理/accent、
   uploader→上传/amber、downloader→下载/emerald、viewer→查看/neutral,多角色其余 +N;
   空角色→「仅访客」;不做归档徽标——GET /projects 恒滤 is_archived 无数据源)。
   素材计数字段后端无,不显示。行尾 chevron 进文件夹列表。
2. **文件夹列表(§8.1)**:`GET /folders?project_id=` 平铺返回全树(含 parent_folder_id),
   自组树按缩进展示,点夹进宫格上下文,支持多级下钻;行=subtree_file_count 徽标
   (仅列表回填)+敏感锁(is_sensitive)+「⋯」菜单**本批占位**(菜单项 B4-B6 填);
   my_can_* 在列表响应恒 False,**勿消费**。
3. **宫格(§8.1)**:进宫格页拉 `GET /folders/{id}` 单夹详情(web useFolder 同源)取
   my_can_upload/my_can_download;3 列缩略图;`tags.thumbnail_key` 存在才请求
   thumbnail-url;**缩略图缓存**:URL+过期时间内存缓存、presigned 30min 过期重签、
   同 URL 并发去重、LRU 上限约 80MB、失败降级类型色块;视频时长角标(duration 字段
   核对后端 AssetOut,无则不加)、livp 实况角标(`.livp` 判定);点按=预览,
   **长按=进入多选**(选择态 UI 本批做:选中打勾+底部计数条;操作按钮 B4/B5 点亮,
   本批显示「已选 n 项」+清空)。
4. **预览页(§8.2 detectKind 八类表)**:
   | 类型 | 呈现 |
   | --- | --- |
   | image(png/jpg/gif/webp/svg/bmp/avif/ico) | 原图 presigned(download-link inline)或 D4 缩略图(1024px)大图;svg/avif/ico 超出 Flutter 解码,无缩略图降级色块+「下载后打开」 |
   | heic/heif | 缩略图(1024px,D4) |
   | livp | 静态图=缩略图;实况短片=live-preview-url+video_player |
   | video(mp4/mov/webm/m4v) | download-link(inline)+video_player;起播/解码失败(Android HEVC .mov)→降级「下载后打开」 |
   | markdown/text | flutter_markdown_plus/纯文本(download-link 拉取) |
   | pdf | dio 下载临时文件→iOS share_plus/Android 占位(B4 media_store_plus 落 Downloads 前先色块+「下载后打开」) |
   | unsupported | 类型色块+「下载后打开」 |
   判定=扩展名优先(点文件钉子:pathlib suffix='' 教训,Dart 侧 endswith 判);
   结构:暗色画布(#141210)+顶部 ‹n/N›+胶片条(当前列表序列切张,边界即停)+
   底部元数据卡(文件名/大小/类型/时间/标签 chips+备注;「编辑」按钮 B5 点亮,
   本批隐藏);操作:下载/分享/申请权限三钮**占位禁用**(灰置,tooltip「后续版本」);
   下载权判定=folder.my_can_download 控制下载钮 disabled 态(false 禁用+「申请权限」
   入口样式提示,实际申请动作 B5)。
5. **数据新鲜度(§8.1)**:写操作(上传/删除等)成功后失效对应列表;从下级页返回按需
   刷新,防 IndexedStack 挂陈旧数据(本批只有上传有写操作——沿用现役 upload 成功
   刷新;通用化列表失效机制)。
6. **依赖(§12)**:`video_player`、`flutter_markdown_plus`、`share_plus` 三包 pub add
   锁版本+pubspec 注释(用途/批次)。share_plus 本批仅 pdf iOS 分享面板用。
7. **架构(§9)**:features/projects/projects_page 徽标升级;features/folders 树化;
   features/assets 宫格升级+多选态;新增 features/preview/(preview_page/filmstrip/
   meta_panel)+core/thumbnail_cache.dart(可单测纯逻辑:URL 过期/并发去重/LRU 驱逐);
   widgets/ 补类型色块、角标。单文件 ≤200 行目标/300 硬顶,不引状态管理框架。

## 数据库修改方案 / 后端改动

不涉及(零后端改动;**禁止改 material-storage/api/ 与 web/**)。

## 测试功能点

1. detectKind 移动版类型判定(八类+扩展名优先+点文件 endswith)。
2. 缩略图缓存纯逻辑:过期重签判定/同 URL 并发去重(单飞)/LRU 驱逐顺序。
3. ROLE_META 徽标映射(四角色+多角色+N+仅访客)。
4. 文件夹树组树(parent_folder_id 多级/孤儿节点容错)。
5. 预览胶片条切张(边界即停/序列正确)。
6. my_can_download=false→下载钮禁用。
7. 回归:现役 70 用例全绿;上传链路不回归。

## 模糊点与决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | pdf Android 端 B2 先色块占位,B4 随落盘矩阵点亮 | media_store_plus 已在但落盘矩阵属 B4 |
| 2 | 长按多选本批做选择态,操作栏 B4 起逐步点亮 | 方案 §8.1/§16 B4(操作栏壳) |
| 3 | share_plus 提前到 B2 引入 | pdf iOS 分享面板本批就需要(§8.2) |

## 项目约定

同 B0+B1 批(Flutter 路径/镜像变量/analyze+test 自测/单文件纪律/不 commit)。
