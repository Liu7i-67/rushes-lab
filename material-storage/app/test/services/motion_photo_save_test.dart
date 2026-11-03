/// 安卓实况图下载编排单测(2026-11-02 方案 §7 第 3 条全集):
/// 注入假 DownloadIo / 假 flm(generate)/ 假权限 / 假 saveImage,PC 零平台
/// 通道、零网络。覆盖:快路径合成 / 自校验失败→D1(对抗样本=「image 半段
/// 拦腰截断、video 尾与 XMP 长度完好」——该形态下输出 image 尾 32B 必不等于
/// 输入尾段;只构造 video 侧畸形的用例对本防线是假绿)/ unpacked 补抓成功 /
/// unpacked 404→D1 / 403·超时外溢 / heic 补抓(含 jpg-only 退化)/ 解包失败
/// →D1 / flm 异常→D1 / 无视频→saveImage(不补抓)/ m4v 退化 / 空间分档
/// (free∈(4×,6×) 走 D1、≥6× 合成、≤4× 中止)/ freeBytes=null 放行 / 进度
/// 映射:首段完成 0.95、补抓恒 0.95、无时刻 >0.95 且无回跳 / 临时清理 /
/// 取消透传(fetch 后取消删临时)/ 同名走 photo_manager(断言不触
/// media_store_plus 入相册)/ 权限拒绝→D1 / 残缺临时不进 D1 / 大小闸门
/// >150MB 直接 D1 / 回落不重入 motion 分流(capable 机回落无二次分流)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart'
    show CancelToken, DioException, DioExceptionType, RequestOptions, Response;
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart' show ApiException;
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/downloads.dart';
import 'package:ms_app/services/media_save.dart';
import 'package:ms_app/services/motion_photo_save.dart';

Asset _asset(
  String filename, {
  required int size,
  String ct = 'application/zip',
}) => Asset(
  id: 'a-$filename',
  filename: filename,
  sizeBytes: size,
  contentType: ct,
  createdAt: '2026-11-02T00:00:00Z',
);

// ── 字节 fixture(最小 JPEG SOI+尾段确定 / 伪 mp4 ftyp 头 / heic·mov·m4v)──

final _jpg = <int>[0xFF, 0xD8, ...List.generate(64, (i) => i & 0xFF)];
final _mp4 = <int>[
  0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, // size box + 'ftyp'(守卫 5 强特征)
  ...List.generate(1100, (i) => (i * 7) & 0xFF), // ≥1KB(自校验 minVideoBytes 守卫)
];
final _heic = <int>[
  0,
  0,
  0,
  32,
  0x66,
  0x74,
  0x79,
  0x70,
  0x68,
  0x65,
  0x69,
  0x63,
];
final _mov = <int>[0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74];
final _m4v = <int>[0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34];

/// GContainer+MicroVideo 双标记(flm 默认模板形态;区间一致 → gcontainer)。
String _motionXmp(int videoLen) =>
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF rdf:about="" '
    'GCamera:MotionPhoto="1" GCamera:MicroVideo="1" '
    'GCamera:MicroVideoOffset="$videoLen"><Container:Directory>'
    '<Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/>'
    '<Container:Item Item:Semantic="MotionPhoto" Item:Mime="video/mp4" '
    'Item:Length="$videoLen"/></Container:Directory></rdf:RDF></x:xmpmeta>';

/// 模拟 flm 产物字节形态:JPEG 骨架(SOI+APP1(XMP)+EOI)+ 输入主图原字节 +
/// 输入视频原字节(尾段/头段确定性成立)。[truncateTail]=对抗样本:image 半段
/// 拦腰截断(去尾 64B),video 尾与 XMP 长度仍完好——自校验必须拦下。
List<int> _motionProduct({
  required List<int> image,
  required List<int> video,
  bool truncateTail = false,
}) {
  final xmp = utf8.encode(_motionXmp(video.length));
  final payload = utf8.encode('http://ns.adobe.com/xap/1.0/\x00') + xmp;
  final app1 = <int>[
    0xFF,
    0xE1,
    (payload.length + 2) >> 8,
    (payload.length + 2) & 0xFF,
    ...payload,
  ];
  final imgPart = truncateTail ? image.sublist(0, image.length - 64) : image;
  return <int>[0xFF, 0xD8, ...app1, 0xFF, 0xD9, ...imgPart, ...video];
}

List<int> _zip(Map<String, List<int>> entries) {
  final arc = Archive();
  entries.forEach((name, bytes) {
    arc.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(arc)!;
}

/// ZIP_STORED 版(zip 长度≈条目原长;补抓空间复检用例按字节数可控)。
List<int> _zipStored(Map<String, List<int>> entries) {
  final arc = Archive();
  entries.forEach((name, bytes) {
    arc.addFile(ArchiveFile(name, bytes.length, bytes)..compress = false);
  });
  return ZipEncoder().encode(arc)!;
}

/// 轮询等待(fire-and-forget 删除落定的窗口)。
Future<bool> _until(bool Function() cond, {int maxMs = 2000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: maxMs));
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return cond();
}

// ── 假件 ──

class FakeSavers {
  FakeSavers({this.ok = true});
  bool ok;
  final galleryCalls = <GalleryAction>[];
  final downloadsCalls = <File>[];
  PlatformSavers build() => PlatformSavers(
    gallery: (f, a) async {
      galleryCalls.add(a);
      return ok
          ? const SinkOutcome.ok('Pictures/x')
          : const SinkOutcome.fail('gallery fail(模拟)');
    },
    downloads: (f) async {
      downloadsCalls.add(f);
      return ok
          ? const SinkOutcome.ok('Download/浣花视界/x')
          : const SinkOutcome.fail('downloads fail(模拟)');
    },
    share: (f) async => const SinkOutcome.ok('已弹出分享面板'),
  );
}

/// 假 IO 束:link 记录 (filename, variant) 并可注入 variant 轨错误;fetch 按
/// savePath 是否含 `_unpacked` 分原始档/补抓档字节,可注入错误(先写残缺
/// 半截再抛,复刻现状「残缺临时保留」暴露面);独占 tempRoot 供残留断言。
class FakeIo {
  FakeIo({this.free = 1 << 40, this.originalBytes, this.refetchBytes});

  int? free; // null → freeBytes 返回 null(unknown 语义)
  List<int>? originalBytes;
  List<int>? refetchBytes;
  Object? linkError; // variant='unpacked' 的 link 抛出
  Object? fetchError; // 原始档轨 fetch 抛出(写残缺半截后)
  Object? refetchFetchError; // 补抓轨 fetch 抛出(404=D1;403/超时=外溢)
  bool cancelAfterFetch = false;
  final links = <(String, String?)>[];
  final fetchPaths = <String>[];
  final toasts = <String>[];
  Directory? _root;

  Future<Directory> get root async =>
      _root ??= await Directory.systemTemp.createTemp('motion_save_test');

  DownloadIo bundle(FakeSavers savers) => DownloadIo(
    link: (a, {variant}) async {
      links.add((a.filename, variant));
      if (variant != null && linkError != null) throw linkError!;
      return 'http://presigned/${variant ?? 'orig'}/${a.filename}';
    },
    fetch:
        ({
          required url,
          required savePath,
          required totalBytes,
          required onProgress,
          required token,
        }) async {
          fetchPaths.add(savePath);
          final f = File(savePath);
          final isRefetch = savePath.contains('_unpacked');
          final err = isRefetch ? refetchFetchError : fetchError;
          if (err != null) {
            await f.writeAsBytes(const [1, 2, 3]); // 残缺半截
            throw err;
          }
          final bytes = (isRefetch ? refetchBytes : originalBytes) ?? const [1];
          await f.writeAsBytes(bytes);
          // 完成事件:contentLength 透传真实字节长(dio 语义取响应 Content-Length,
          // 与资产 sizeBytes 可不同——补抓段空间复检即按此取数)
          onProgress(bytes.length, bytes.length);
          if (cancelAfterFetch) token.cancel('用户取消');
          return f;
        },
    freeBytes: (_) async => free,
    tempRoot: () => root,
    savers: savers.build(),
    toast: toasts.add,
  );

  Future<void> dispose() async {
    final r = _root;
    if (r != null) {
      try {
        await r.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 假 flm(generate 注入束):按输入 image/video 构造产物(可选对抗样本);
/// 产物落在 io 独占 root 内,成功路径清理后应一并消失。
class FakeGenerate {
  FakeGenerate({this.truncateTail = false, this.boom = false});
  final bool truncateTail;
  final bool boom;
  final calls = <String>[];
  int _seq = 0;

  Future<String> call({
    required String imagePath,
    required String videoPath,
    Directory? root,
  }) async {
    calls.add('$imagePath+$videoPath');
    if (boom) throw StateError('flm boom(模拟)');
    final image = await File(imagePath).readAsBytes();
    final video = await File(videoPath).readAsBytes();
    final out = File('${root!.path}/MVIMG_${_seq++}_MP.jpg');
    await out.writeAsBytes(
      _motionProduct(image: image, video: video, truncateTail: truncateTail),
    );
    return out.path;
  }
}

void main() {
  late FakeIo io;
  late FakeSavers savers;
  final progress = <int>[];
  final saved = <(String, String)>[]; // (path, title)
  var granted = true;
  Object? saveImageError;
  late FakeGenerate generate;

  Future<void> run({Asset? withAsset}) => runMotionPhotoDownload(
    asset:
        withAsset ?? _asset('IMG_0001.livp', size: 1000, ct: 'application/zip'),
    onProgress: progress.add,
    token: CancelToken(),
    io: io.bundle(savers),
    generate: ({required imagePath, required videoPath}) => generate.call(
      imagePath: imagePath,
      videoPath: videoPath,
      root: io._root,
    ),
    ensureGalleryPermission: () async => granted,
    saveImage: (path, title) async {
      if (saveImageError != null) throw saveImageError!;
      saved.add((path, title));
      return null;
    },
  );

  setUp(() async {
    io = FakeIo(
      originalBytes: _zip({'IMG_0001.jpg': _jpg, 'IMG_0001.mp4': _mp4}),
    );
    savers = FakeSavers();
    progress.clear();
    saved.clear();
    granted = true;
    saveImageError = null;
    generate = FakeGenerate();
  });
  tearDown(() => io.dispose());

  group('快路径(jpg+mp4)合成 + 入相册', () {
    test('合成成功:photo_manager 入相册({base}.jpg)、不触 media_store_plus、'
        '不写 Downloads、临时/解包目录/flm 产物全清', () async {
      await run();
      expect(generate.calls, hasLength(1), reason: '解包 jpg+mp4 直合成本地零额外请求');
      expect(io.links.single.$2, isNull, reason: '原始档 link 不带 variant');
      expect(
        saved.single.$2,
        'IMG_0001.jpg',
        reason: 'title 基名 .jpg 结尾(MIME 推断)',
      );
      expect(
        savers.galleryCalls,
        isEmpty,
        reason: '成功路径不走 runSavePlan/gallerySaver',
      );
      expect(
        savers.downloadsCalls,
        isEmpty,
        reason: '合成成功不再写 Downloads 原档(D3);downloads 即 media_store_plus 路',
      );
      expect(io.toasts.single, contains('实况图已存入相册'));
      expect(
        await _until(() => io._root!.listSync().isEmpty),
        isTrue,
        reason: '原档临时+解包目录+flm cache 产物 finally 全清(幂等静默)',
      );
    });

    test('进度映射:整链 [0,0.95]——首段完成报 0.95,无任何时刻 >0.95 且无回跳', () async {
      await run();
      expect(
        progress,
        everyElement(lessThanOrEqualTo(950)),
        reason: 'sizeBytes=1000 → 0.95 上界=950',
      );
      expect(progress.last, 950);
      for (var i = 1; i < progress.length; i++) {
        expect(
          progress[i],
          greaterThanOrEqualTo(progress[i - 1]),
          reason: '无回跳',
        );
      }
    });

    test('输入条目校验不过(image 非 SOI / video 非 ftyp)→ D1,不进合成', () async {
      io.originalBytes = _zip({'IMG.jpg': _heic, 'IMG.mp4': _mp4}); // 改名 HEIC
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('自校验失败→D1(对抗样本:image 半段拦腰截断、video 尾与 XMP 长度完好)', () async {
      generate = FakeGenerate(truncateTail: true);
      await run();
      expect(generate.calls, hasLength(1), reason: 'flm 已产出,自校验拦在入相册前');
      expect(saved, isEmpty, reason: '可疑产物不落盘');
      expect(savers.galleryCalls, [
        GalleryAction.saveLivpPair,
      ], reason: 'D1 收尾:gallery 解包双存');
      expect(
        savers.downloadsCalls,
        hasLength(1),
        reason: 'D1 收尾:原档写 Downloads',
      );
      expect(io.toasts.single, contains('已存入相册'), reason: 'D1 沿用 saveSummary');
    });

    test('flm 异常→D1 收尾(原始档已在手,零额外请求)', () async {
      generate = FakeGenerate(boom: true);
      await run();
      expect(io.links, hasLength(1), reason: '仅原始档一次 link,无补抓');
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('权限拒绝→D1(权限前置显式复刻,不进合成)', () async {
      granted = false;
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('saveImage 抛错→D1', () async {
      saveImageError = StateError('save boom(模拟)');
      await run();
      expect(saved, isEmpty);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('解包失败(zip 损坏)→ D1 收尾', () async {
      io.originalBytes = const [9, 9, 9, 9];
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });
  });

  group('无视频 / m4v → D7 静图退化', () {
    test('无视频条目:saveImage 收尾(title=条目名,勿强制 .jpg),不补抓 unpacked', () async {
      io.originalBytes = _zip({'IMG_0001.heic': _heic});
      await run();
      expect(io.links, hasLength(1), reason: '不付 unpacked 请求(原档静图已可用)');
      expect(io.fetchPaths, hasLength(1), reason: '无补抓段');
      expect(saved.single.$2, 'IMG_0001.heic');
      expect(savers.downloadsCalls, isEmpty, reason: '退化即完成,不写 Downloads');
      expect(io.toasts.single, contains('静态帧已存入相册'));
    });

    test('m4v 视频条目:按无视频退化(m4v 不付 unpacked——后端只认 mov/mp4)', () async {
      io.originalBytes = _zip({'IMG.jpg': _jpg, 'IMG.m4v': _m4v});
      await run();
      expect(io.links, hasLength(1));
      expect(saved.single.$2, 'IMG.jpg');
      expect(io.toasts.single, contains('静态帧已存入相册'));
    });
  });

  group('按需补抓 variant=unpacked(heic/mov/png)', () {
    setUp(() {
      io.originalBytes = _zip({'IMG_0001.heic': _heic, 'IMG_0001.mov': _mov});
      io.refetchBytes = _zip({'IMG_0001.jpg': _jpg, 'IMG_0001.mp4': _mp4});
    });

    test('补抓成功:link 带 unpacked、二次解包合成、补抓段进度恒 0.95 无回跳', () async {
      await run();
      expect(io.links.map((l) => l.$2), [
        isNull,
        'unpacked',
      ], reason: '原始档一次(不带 variant)+ 补抓一次(带 unpacked)');
      expect(generate.calls, hasLength(1));
      expect(saved.single.$2, 'IMG_0001.jpg');
      expect(
        progress,
        everyElement(equals(950)),
        reason: 'heic 输入:首段映射至 0.95 后,补抓段每拍恒报 0.95(size=1000)',
      );
    });

    test('补抓 404(link 层)→ D1 收尾;404 不重派资产亦同路(恒 404 接受)', () async {
      io.linkError = ApiException(404, 'not found');
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('补抓 404(fetch/presigned 层 DioException badResponse)→ D1', () async {
      // 两层 404 异常形态不同:link 层 ApiException vs 裸 presigned GET 层
      // DioException——判定统一收口 legacy_download.isNotFound
      io.refetchFetchError = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 404,
        ),
      );
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('补抓 403 / 超时 → 任务失败外溢(残缺临时不进 D1)', () async {
      io.refetchFetchError = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 403,
        ),
      );
      await expectLater(
        run(),
        throwsA(isA<DioException>()),
        reason: '仅 404 走 D1;403/超时/5xx=任务失败外溢',
      );
      expect(savers.galleryCalls, isEmpty, reason: '外溢路径不进 D1 收尾');
      expect(savers.downloadsCalls, isEmpty);
    });

    test('补抓 link 403 → 外溢(ApiException 非 404 不收 D1)', () async {
      io.linkError = ApiException(403, '无权下载');
      await expectLater(run(), throwsA(isA<ApiException>()));
      expect(savers.galleryCalls, isEmpty);
    });

    test('补抓解包失败(zip 损坏)→ D1', () async {
      io.refetchBytes = const [7, 7, 7];
      await run();
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('补抓后「仅 jpg 的 zip」(mov 转码失败降级)→ 静图退化', () async {
      io.refetchBytes = _zip({'IMG_0001.jpg': _jpg});
      await run();
      expect(generate.calls, isEmpty);
      expect(saved.single.$2, 'IMG_0001.jpg');
      expect(io.toasts.single, contains('静态帧已存入相册'));
    });

    test('补抓档落地后剩余空间不足 → D1(Content-Length 复检)', () async {
      // free=6001 先过 6× 合成闸(gate1),补抓 len 复检按 4× 补抓档估——
      // refetch mp4 加大到 ~2KB,4× zip 远超 free → 放弃合成走 D1
      final bigMp4 = <int>[
        0x66,
        0x74,
        0x79,
        0x70,
        ...List.generate(2048, (i) => (i * 3) & 0xFF),
      ];
      io.refetchBytes = _zipStored({
        'IMG_0001.jpg': _jpg,
        'IMG_0001.mp4': bigMp4,
      });
      io.free = 6001;
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.downloadsCalls, hasLength(1), reason: 'D1 收尾');
    });
  });

  group('步骤 0/1 闸门与 D1 回落', () {
    test('大小闸门:>150MB 直接 D1,不进合成链(链接仅一次原始档)', () async {
      final a = _asset('big.livp', size: 151 * 1024 * 1024);
      await run(withAsset: a);
      expect(generate.calls, isEmpty);
      expect(io.links, hasLength(1));
      expect(io.links.single.$2, isNull);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
    });

    test('空间分档:free∈(4×,6×) 不中止、直接 D1 回落(放弃合成)', () async {
      io.free = 5000; // 4×=4000 过检,6×=6000 不足
      await run();
      expect(generate.calls, isEmpty);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
      expect(savers.downloadsCalls, hasLength(1));
      expect(io.toasts.single, contains('已存入相册'), reason: '回落走现状 legacy 全流程');
    });

    test('空间分档:free≥6× 进合成链', () async {
      io.free = 6000;
      await run();
      expect(generate.calls, hasLength(1));
    });

    test('空间分档:free≤4× 中止于预检(现状中止语义,不发任何请求)', () async {
      io.free = 4000; // checkSpace 相等即不足(保守中止)
      await expectLater(
        run(),
        throwsA(
          isA<SaveAbortException>().having(
            (e) => e.message,
            'message',
            contains('空间不足'),
          ),
        ),
      );
      expect(io.links, isEmpty);
      expect(io.fetchPaths, isEmpty);
    });

    test('freeBytes=null(df 失败)沿现状 unknown 语义放行进合成链', () async {
      io.free = null;
      await run();
      expect(generate.calls, hasLength(1));
    });

    test('回落不重入 motion 分流:capable 机回落无二次分流(经 runDownloadJob)', () async {
      io.originalBytes = const [9, 9, 9, 9]; // 非 zip → motion 解包失败 → D1 回落
      var capableCalls = 0;
      await runDownloadJob(
        asset: _asset('IMG_9.livp', size: 1000),
        onProgress: (_) {},
        token: CancelToken(),
        platform: SavePlatform.android,
        io: io.bundle(savers),
        motionCapable: () async {
          capableCalls += 1;
          return true;
        },
      );
      expect(
        capableCalls,
        1,
        reason: 'D1 回落直调 legacy 主体,不经 runDownloadJob 顶部再分流',
      );
      expect(
        io.fetchPaths.length,
        1,
        reason: '解包失败的 D1 收尾复用原始档临时(零二次下载);重入分流会再探测再下载',
      );
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair]);
    });
  });

  group('取消与残缺临时', () {
    test('fetch 后取消:删临时静默返回,不落盘不通知(P2-2)', () async {
      io.cancelAfterFetch = true;
      await run();
      expect(savers.galleryCalls, isEmpty);
      expect(savers.downloadsCalls, isEmpty);
      expect(io.toasts, isEmpty);
      expect(io._root!.listSync(), isEmpty, reason: '临时已补删');
    });

    test('fetch 网络异常(首段)→ 任务失败外溢:残缺临时保留,不进 D1', () async {
      io.fetchError = DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: '/x'),
      );
      await expectLater(run(), throwsA(isA<DioException>()));
      expect(savers.galleryCalls, isEmpty, reason: '残缺临时不能进 D1 存相册');
      expect(savers.downloadsCalls, isEmpty);
      expect(
        File(io.fetchPaths.single).existsSync(),
        isTrue,
        reason: '残缺临时对齐现状不删保留(app cache 系统可回收)',
      );
    });
  });
}
