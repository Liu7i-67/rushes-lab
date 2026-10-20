# 浣花视界 App 完整版 · B4 下载线需求文档

> 2026-10-20 · qdev 链式第 3 批。上位方案 §6(下载与双端落盘)/§8.2(pdf)/§16 B4。
> worktree:`E:\qbb\github_not_me\rushes-lab-feat-mobile-app-b2-b9`(B3 后)。
> 交付判据:**Android 图库+Downloads 双可见**(真机终验);PC=analyze+test 全绿。

## 功能点明细

1. **落盘矩阵(§6.1,核心)**:`services/media_save.dart` 纯函数策略路由(平台×类型,
   可单测)+平台执行件:
   | 资产 | iOS | Android |
   | --- | --- | --- |
   | .livp | 解包→存相册恢复实况(现役 saveLivpToAlbum);解包/存相册失败→原档兜底 share_plus「存储到文件」 | **D1 双落盘**:①解包→静态图+视频分别存图库 ②.livp 原档写 Downloads/浣花视界/;两路分别记成功/失败,失败路单独重试,互不阻塞 |
   | 图片/视频 | PhotoManager.editor 存相册 | 同左(photo_manager 双端 API);失败兜底 media_store_plus 直写 Downloads |
   | 其他文件(含 pdf) | share_plus 面板(「存储到文件」) | media_store_plus 写 Downloads |
   钉子:**media_store_plus saveFile 成功亦返 null,勿以返回值判成败、以无异常为准**;
   saveFile 内部会删源文件——**每路独立副本**(B0 PoC 已验证);galleryStrategy 为 skip
   的路短路跳过复制(B0 PoC 遗留优化);**API<29 不支持**(内网工具,最低 Android 10,
   真机基线已定)。
2. **下载编排**:download-link → dio 落 app cache(进度回调进 TransferQueue)→ 按
   矩阵落盘 → **落盘成功后删临时文件**(D1 双落盘共用一次下载);空间预检(原档+解包
   估算,不足提示并中止);重名不覆盖自动序号(media_store_plus/图库行为);toast 明说
   去处(「已存入相册」「已存入 Download/浣花视界」)。
3. **下载任务入队**:TransferQueue kind=download(进度/取消/重试从头);重试语义=
   重新下载+重新落盘(已成功落盘路由重试时提示已存在,不重复副本——按平台行为)。
4. **入口点亮**:①预览页「下载」钮启用(my_can_download==false 仍禁用+申请提示);
   ②宫格操作栏壳:多选态底部操作栏本批亮「下载」键(其余键 B5)——批量下载逐文件
   入队,>20 确认弹窗(桌面 web 同款);③B0 PoC 落盘验证页**移除**(使命完成,正式
   实现取代;诊断区入口去掉)。
5. **pdf Android 补齐(§8.2)**:预览 pdf 的 Android 分支从占位色块改「下载后打开」
   语义(下载→Downloads→toast)。
6. **B2/B3 遗留 P2 清偿(本批顺带,测试者挂账)**:
   - B2:preview_media.dart 431 行拆分(player/plan/text-load 拆出);livp「查看照片」
     显示静态缩略图而非暂停帧(plan 补 playingLive 维度);core→features 环引用解耦
     (Session 暴露回调或 clear 挂 cache 侧);md/text 断流观察项(P2-D 无需代码,
     真机观察清单化)。
   - B3:_fetchEpoch 代际丢弃致全屏 loading 永久卡死(被丢弃的全屏分支仍清 _loading
     或静默 swap 时一并清);upload_sheet.dart 348 行/assets_page.dart 332 行拆回
     300 硬顶内;文件选择器失败静默补 toast(与相册路一致)。
7. **架构(§9)**:services/media_save.dart(纯函数矩阵)+services/downloads.dart
   (media_store_plus 封装+下载编排);单文件 ≤200 目标/300 硬顶(拆分后全合规);
   不引新包(media_store_plus/share_plus/dio 均已在)。

## 数据库/后端改动

不涉及。契约自查:`material-storage/api/app/routers/assets.py` download-link。

## 测试功能点

1. 落盘矩阵纯函数:平台×类型全组合(含 skip 短路、D1 双路声明)。
2. 空间预检边界(不足→中止不半途写坏;富余→放行)。
3. 下载编排:进度回传入队、落盘成功删临时、失败保留临时可重试、D1 共用一次下载。
4. 批量下载:>20 确认门槛;逐文件入队。
5. livp Android 解包双存(静态图+视频分别);失败路单独重试互不阻塞(编排层可测)。
6. saveFile null→ok 语义沿用(B0 用例保持);skip 路不复制。
7. _fetchEpoch 卡死修复:全屏在途+静默先完成场景 loading 必清。
8. 回归:现役 164 用例全绿;上传/传输/预览链路不回归。

## 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | B0 PoC 页移除(含路由/测试) | 使命完成,正式实现取代;方案 §16 决策 #5 |
| 2 | 平台执行件(PhotoManager/media_store/share)注入化,PC 单测不触平台通道 | 沿 B0 可注入模式 |
| 3 | 重试不查重已落盘(平台序号防重复副本) | 简单;平台重名自动加后缀语义已覆盖 |

## 项目约定

同前批。
