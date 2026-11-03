/// 安卓实况图(Motion Photo)下载编排(2026-11-02 方案 §5.4,步骤号即文档步骤):
/// 独立于 D1 矩阵(「单产物多级降级链」形状不同,planSaveRoutes 不动,回滚面最小)。
/// 0/1 大小/空间闸门(不过→D1 回落 runLegacyDownloadJob,不经 runDownloadJob 顶部
/// motion 分流防 capable 机重入死循环)→ 2 下载原始档(进度映射 [0,0.95];fetch 网络
/// 异常=任务失败外溢,残缺临时不进 D1)→ 3 解包分诊(jpg+mp4 快路径 / heic/mov/png
/// 补抓 variant=unpacked(仅 404 走 D1,motion_photo_refetch.dart 拆件)/ 无视频或
/// m4v 静图退化)→ 4 flm 合成 → 三段定点读自校验(motion_photo_verify.dart 拆件)→
/// photo_manager saveImageWithPath 入相册(同名系统加后缀,不触 media_store_plus)→
/// 5 失败 D1 收尾(先幂等清中间产物仅留原始档,再现状 runSavePlan+finishDownloadSave)
/// → 6 成功清理 → 7 文案/通知/打点。flm 封装经 [MotionPhotoGenerator] 注入(D6 后路=内联实现,替换零波及);IO 全走 [DownloadIo] 注入束,PC 单测零平台通道、零网络。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_live_motion/flutter_live_motion.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/fmt.dart' show fmtBytes;
import '../core/transfers/transfer_task.dart' show TransferKind;
import '../models/models.dart';
import 'app_log.dart';
import 'downloads.dart' show DownloadIo;
import 'legacy_download.dart' show finishDownloadSave, runLegacyDownloadJob;
import 'livp.dart' show LivpService;
import 'media_save.dart';
import 'motion_photo_refetch.dart'
    show
        RefetchArtifacts,
        RefetchSink,
        motionExtOf,
        motionFirstSegmentProgress,
        refetchUnpackedInputs;
import 'motion_photo_verify.dart';
import 'notifier.dart';

/// 大小闸门(镜像上传侧 150MB):flm 原生 ≈2-3× 原件常驻,OutOfMemoryError 非 Exception 不可捕获 → 超限直接 D1 不进合成链。
const kMotionMaxSourceBytes = 150 * 1024 * 1024;

/// 空间分档:≥6× 才进合成链(补抓支路最坏驻留≈5×,留裕度);[4×,6×) 不中止直接 D1(该空间带行为与今日一致);≤4× 由现状预检中止。
const kMotionComposeSpaceFactor = 6;

/// flm 合成注入缝(D6):Android 返回 cacheDir 产物路径;iOS 不在本方案调用。
typedef MotionPhotoGenerator = Future<String> Function({
  required String imagePath,
  required String videoPath,
});

/// 生产 flm 封装(generate 返回 dynamic,Android 形态为产物路径 String)。
MotionPhotoGenerator defaultMotionPhotoGenerator() {
  final flm = FlutterLiveMotion();
  return ({required imagePath, required videoPath}) async =>
      (await flm.generate(imagePath: imagePath, videoPath: videoPath))
          as String;
}

/// 相册权限前置(_ensureGalleryPermission 同款显式复刻——成功路径不走 runSavePlan/gallerySaver,权限链不会自动继承);查询异常按未授权 → D1。
Future<bool> defaultEnsureGalleryPermission() async {
  try {
    final state = await PhotoManager.requestPermissionExtend();
    AppLog.info('motion', '相册权限 state=$state');
    return state.isAuth;
  } catch (e) {
    AppLog.error('motion', '相册权限查询失败,按未授权处理', e);
    return false;
  }
}

/// 入相册(photo_manager saveImageWithPath,与 D1 静图路同一 API)。
Future<AssetEntity?> defaultSaveMotionImage(String path, String title) =>
    PhotoManager.editor.saveImageWithPath(path, title: title);

/// 安卓实况图下载编排(livp 资产;link 的 variant 缺省=原始档;注入参缺省=真实实现,测试注入假件零平台通道)。
Future<void> runMotionPhotoDownload({
  required Asset asset,
  required void Function(int doneBytes) onProgress,
  required CancelToken token,
  required DownloadIo io,
  MotionPhotoGenerator? generate,
  Future<bool> Function()? ensureGalleryPermission,
  Future<AssetEntity?> Function(String path, String title)? saveImage,
}) async {
  final doGenerate = generate ?? defaultMotionPhotoGenerator();
  final ensurePerm = ensureGalleryPermission ?? defaultEnsureGalleryPermission;
  final doSaveImage = saveImage ?? defaultSaveMotionImage;
  final total = asset.sizeBytes.toInt();
  final plan = planSaveRoutes(
    platform: SavePlatform.android,
    kind: SaveAssetKind.livp,
  );
  final root = await io.tempRoot();

  // ── 步骤 0:大小闸门(先于一切)──
  if (total > kMotionMaxSourceBytes) {
    AppLog.info(
      'motion',
      '${asset.filename} 超过 ${fmtBytes(kMotionMaxSourceBytes)},不进合成链',
    );
    return _fallbackLegacy(asset, onProgress, token, io);
  }

  // ── 步骤 1:空间分档(4× 现状预检不足→现状中止;[4×,6×) 放弃合成直接 D1;free=null 沿现状 unknown 语义放行)──
  final required = estimateRequiredBytes(total, plan); // 现状 D1 口径=4×
  final free = await io.freeBytes(root.path);
  if (checkSpace(free, required) == SpaceVerdict.insufficient) {
    throw SaveAbortException(
      '空间不足:预计需 ${fmtBytes(required)},该目录仅剩 ${fmtBytes(free!)},已中止下载',
    );
  }
  if (free != null && free < total * kMotionComposeSpaceFactor) {
    AppLog.info(
      'motion',
      '${asset.filename} 剩余空间不足 $kMotionComposeSpaceFactor×,放弃合成走 D1',
    );
    return _fallbackLegacy(asset, onProgress, token, io);
  }

  // ── 步骤 2:下载原始档(fetch 网络异常=任务失败外溢,残缺临时不进 D1)──
  final url = await io.link(asset);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final temp = await io.fetch(
    url: url,
    savePath: '${root.path}/dl_${stamp}_${baseNameOf(asset.filename)}',
    totalBytes: total,
    onProgress: motionFirstSegmentProgress(onProgress, total),
    token: token,
  );
  if (token.isCancelled) {
    // 取消竞态(P2-2 同款):删临时直接返回,不落盘不通知
    await deleteQuietly(temp);
    return;
  }

  // 链上中间产物登记(D1 收尾/成功清理共用;全幂等静默)
  final unpack = await Directory.systemTemp.createTemp('motion_unpack');
  final artifacts = RefetchArtifacts();
  File? flmProduct;
  Future<void> cleanIntermediates() async {
    await deleteQuietly(unpack);
    if (artifacts.zip != null) await deleteQuietly(artifacts.zip!);
    if (artifacts.dir != null) await deleteQuietly(artifacts.dir!);
    if (flmProduct != null) await deleteQuietly(flmProduct);
  }

  /// D1 收尾(§5.4 步骤 5):先幂等删全部中间产物仅留原始档(不先清则降级路径空间峰值高出链上中间产物,窄空间带会「今日能成」变「ENOSPC 全败」),再现状 runSavePlan+共享收尾(全败=SaveAbortException+原档保留取证)。
  Future<void> d1(String reason) async {
    AppLog.info('motion', '${asset.filename} 降级 D1:$reason');
    await cleanIntermediates();
    final outcomes = await runSavePlan(
      file: temp,
      plan: plan,
      savers: io.savers,
    );
    await finishDownloadSave(
      temp: temp,
      outcomes: outcomes,
      asset: asset,
      io: io,
    );
  }

  /// 终态收尾(§5.4 步骤 6/7):幂等清中间产物+原档临时,文案/系统通知。
  Future<void> finishOk(String summary) async {
    await cleanIntermediates();
    temp.delete().ignore();
    AppLog.info('motion', '✓ ${asset.filename} → $summary');
    io.toast?.call('${asset.filename}:$summary');
    Notifier.I.taskFinished(
      kind: TransferKind.download,
      ok: true,
      filename: asset.filename,
      detail: summary,
    );
  }

  /// D7 静图退化收尾:title=条目名(勿强制 .jpg——heic 字节配 image/jpeg 错配);不补抓 unpacked、成功不写 Downloads 原档(D3/D7「退化即完成」);失败照走 D1。
  Future<void> saveStatic(File imageEntry, String reason) async {
    AppLog.info('motion', '${asset.filename} 静图退化($reason)');
    if (!await ensurePerm()) return d1('未获相册权限');
    try {
      await doSaveImage(imageEntry.path, baseNameOf(imageEntry.path));
    } catch (e) {
      AppLog.error('motion', '静图入相册失败', e);
      return d1('静图保存失败:$e');
    }
    return finishOk('静态帧已存入相册(无实况短片)');
  }

  // 补抓支路收口束(onCancel=P2-2 同款:清原档临时+补抓档,静默返回)
  final sink = RefetchSink(
    artifacts: artifacts,
    onD1: d1,
    onStatic: saveStatic,
    onCancel: () async {
      await deleteQuietly(temp);
      await cleanIntermediates();
    },
  );

  // ── 步骤 3:解包分诊 ──
  ({File image, File? video}) parts;
  try {
    parts = await LivpService.unpackToFiles(await temp.readAsBytes(), unpack);
  } catch (e) {
    return d1('livp 解包失败:$e');
  }
  final imgExt = motionExtOf(baseNameOf(parts.image.path));
  final vidExt = parts.video == null
      ? ''
      : motionExtOf(baseNameOf(parts.video!.path));

  // 无视频条目 / m4v → D7 静图退化(m4v 不付 unpacked:后端 unpacked worker 只认 mov/mp4,请求注定只回 jpg)
  if (parts.video == null || vidExt == '.m4v') {
    return saveStatic(
      parts.image,
      parts.video == null ? 'livp 无视频条目' : '视频条目为 m4v',
    );
  }

  File composeImage;
  File composeVideo;
  if ((imgExt == '.jpg' || imgExt == '.jpeg') && vidExt == '.mp4') {
    // 快路径(安卓来源):定点读 image SOI + video ftyp,拦外部异构 livp 的改名 HEIC/假 mp4 条目(防「合成仅静图语义产物且自校验通过」的静默降级)
    final soiOk = await hasJpegSoi(parts.image);
    final ftypOk = soiOk && await hasMp4FtypHeader(parts.video!);
    if (!soiOk || !ftypOk) {
      return d1(
        '输入条目校验不过(${!soiOk ? 'image 非 JPEG SOI' : 'video 非 mp4 ftyp'})',
      );
    }
    composeImage = parts.image;
    composeVideo = parts.video!;
  } else {
    // heic/mov/png(iOS 来源/外部异构)→ 按需补抓 variant=unpacked(仅 404 走 D1,其余网络异常外溢;详见 motion_photo_refetch.dart)
    final r = await refetchUnpackedInputs(
      asset: asset,
      io: io,
      token: token,
      onProgress: onProgress,
      total: total,
      zipPath: '${root.path}/dl_${stamp}_unpacked',
      unpackDir: unpack,
      sink: sink,
    );
    if (r == null) return; // 已在补抓链内收尾(D1/退化/取消)
    composeImage = r.image;
    composeVideo = r.video;
  }

  // ── 步骤 4:合成 + 输出自校验 + 入相册(每步异常 → D1;权限前置显式复刻)──
  if (!await ensurePerm()) {
    return d1('未获相册权限(需「所有照片」+「修改/删除」授权)');
  }
  final String productPath;
  try {
    productPath = await doGenerate(
      imagePath: composeImage.path,
      videoPath: composeVideo.path,
    );
  } catch (e) {
    AppLog.error('motion', 'flm 合成异常', e);
    return d1('flm 合成异常:$e');
  }
  final product = File(productPath);
  flmProduct = product;
  if (!await verifyMotionPhotoProduct(
    product,
    imageTail: await fileTailBytes(composeImage, 32),
    videoHead: await fileHeadBytes(composeVideo, 8),
    videoLength: await composeVideo.length(),
  )) {
    return d1('合成产物自校验失败(ftyp 误命中静默损坏兜底)');
  }
  // 入相册:title 基名必须 .jpg 结尾(MIME 推断),DISPLAY_NAME/MIME 取自 title,产物随机名不影响落地名;不传 relativePath(缺省=MediaStore Images 默认
  // Pictures/ 根,同 D1 静图路落点);同名系统自动加后缀(刻意不用 media_store_plus:其同名=先删后插覆盖替换,跨夹同名先后下载会静默丢旧文件)
  final base = LivpService.baseNameOf(asset.filename, 'IMG_motion');
  try {
    await doSaveImage(productPath, '$base.jpg');
  } catch (e) {
    AppLog.error('motion', '实况图入相册失败', e);
    return d1('实况图入相册失败:$e');
  }
  return finishOk('实况图已存入相册');
}

/// 步骤 0/1 的 D1 回落:直调现状主体(勿回调 runDownloadJob——顶部就是 motion 分流,capable 机重入死循环;platform 定参 android 短路)。
Future<void> _fallbackLegacy(
  Asset asset,
  void Function(int) onProgress,
  CancelToken token,
  DownloadIo io,
) {
  return runLegacyDownloadJob(
    asset: asset,
    onProgress: onProgress,
    token: token,
    io: io,
    platform: SavePlatform.android,
  );
}
