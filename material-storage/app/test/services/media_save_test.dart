/// B4 落盘矩阵纯函数单测(测试功能点 1/2/5;§6.1 平台×类型矩阵全组合):
/// 分类、矩阵路由声明(含 D1 双落盘声明与 skip 短路=无图库路零 IO)、
/// runSavePlan 双路编排(独立副本/互不阻塞/兜底链/副本清理)、空间预检边界、
/// 需求估算与汇总文案。平台执行件全注入假件,PC 不触平台通道。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/media_save.dart';

/// 真实源文件(runSavePlan 多主路时会复制独立副本,必须可读)。
Future<File> _makeSource({String name = 'IMG_0001.jpg'}) async {
  final dir = await Directory.systemTemp.createTemp('media_save_test');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(const [1, 2, 3, 4]);
  return f;
}

Future<void> _cleanupSrc(File src) async {
  try {
    await src.parent.delete(recursive: true);
  } catch (_) {}
}

/// 记录调用的假执行件;[galleryOk]/[downloadsOk]/[shareOk] 控制成败。
class RecordingSavers {
  RecordingSavers({
    this.galleryOk = true,
    this.downloadsOk = true,
    this.shareOk = true,
  });

  final bool galleryOk;
  final bool downloadsOk;
  final bool shareOk;

  final galleryCalls = <(File, GalleryAction)>[];
  final downloadsCalls = <File>[];
  final shareCalls = <File>[];

  PlatformSavers savers() => PlatformSavers(
        gallery: (f, a) async {
          galleryCalls.add((f, a));
          return galleryOk
              ? const SinkOutcome.ok('Pictures/IMG_0001.jpg')
              : const SinkOutcome.fail('未获相册权限(模拟)');
        },
        downloads: (f) async {
          downloadsCalls.add(f);
          if (!downloadsOk) return const SinkOutcome.fail('disk full(模拟)');
          await f.delete(); // 复刻 media_store_plus saveFile 搬运后删源
          return const SinkOutcome.ok('Download/浣花视界/x');
        },
        share: (f) async {
          shareCalls.add(f);
          return shareOk
              ? const SinkOutcome.ok('已弹出分享面板')
              : const SinkOutcome.fail('share 失败(模拟)');
        },
      );
}

void main() {
  group('classifyAssetKind(B0 口径沿用)', () {
    test('livp 按扩展名识别(大小写不敏感)', () {
      expect(classifyAssetKind(filename: 'IMG_0001.livp'), SaveAssetKind.livp);
      expect(
          classifyAssetKind(
              filename: 'A.LIVP', contentType: 'application/zip'),
          SaveAssetKind.livp);
    });
    test('图片/视频:content_type 优先,扩展名兜底;其余归 other', () {
      expect(classifyAssetKind(filename: 'a.bin', contentType: 'image/jpeg'),
          SaveAssetKind.image);
      expect(classifyAssetKind(filename: 'v.bin', contentType: 'video/mp4'),
          SaveAssetKind.video);
      expect(classifyAssetKind(filename: 'pic.png'), SaveAssetKind.image);
      expect(classifyAssetKind(filename: 'clip.mov'), SaveAssetKind.video);
      expect(classifyAssetKind(filename: 'doc.pdf'), SaveAssetKind.other);
      expect(classifyAssetKind(filename: 'noext'), SaveAssetKind.other);
    });
  });

  group('planSaveRoutes — §6.1 矩阵全组合(测试功能点 1)', () {
    test('iOS livp:图库解包恢复实况 + 失败兜底 share(不让用户白下载)', () {
      final p = planSaveRoutes(
          platform: SavePlatform.ios, kind: SaveAssetKind.livp);
      expect(p.routes.length, 2);
      expect(p.routes[0].id, SaveRouteId.gallery);
      expect(p.routes[0].galleryAction, GalleryAction.saveLivePhoto);
      expect(p.routes[0].onlyIfAllFailed, isFalse);
      expect(p.routes[1].id, SaveRouteId.share);
      expect(p.routes[1].onlyIfAllFailed, isTrue);
    });

    test('Android livp:D1 双落盘声明——图库双存 + Downloads 原档,双主路并发',
        () {
      final p = planSaveRoutes(
          platform: SavePlatform.android, kind: SaveAssetKind.livp);
      expect(p.routes.length, 2);
      expect(p.routes[0].id, SaveRouteId.gallery);
      expect(p.routes[0].galleryAction, GalleryAction.saveLivpPair);
      expect(p.routes[1].id, SaveRouteId.downloads);
      expect(p.routes.every((r) => !r.onlyIfAllFailed), isTrue,
          reason: 'D1:两路无条件并发、分别记成败、互不阻塞');
    });

    test('图片/视频:双端图库;Android 失败兜底 Downloads;iOS 无兜底', () {
      for (final kind in [SaveAssetKind.image, SaveAssetKind.video]) {
        final action = kind == SaveAssetKind.image
            ? GalleryAction.saveImage
            : GalleryAction.saveVideo;
        final ios =
            planSaveRoutes(platform: SavePlatform.ios, kind: kind);
        expect(ios.routes.length, 1, reason: '$kind');
        expect(ios.routes[0].galleryAction, action);

        final droid =
            planSaveRoutes(platform: SavePlatform.android, kind: kind);
        expect(droid.routes.length, 2, reason: '$kind');
        expect(droid.routes[0].galleryAction, action);
        expect(droid.routes[1].id, SaveRouteId.downloads);
        expect(droid.routes[1].onlyIfAllFailed, isTrue,
            reason: '$kind:Downloads 是图库失败兜底,非 D1 双落盘');
      }
    });

    test('其他文件(含 pdf):iOS share 面板 / Android Downloads;'
        '无图库路=skip 短路零复制', () {
      final ios =
          planSaveRoutes(platform: SavePlatform.ios, kind: SaveAssetKind.other);
      expect(ios.routes.single.id, SaveRouteId.share);
      final droid = planSaveRoutes(
          platform: SavePlatform.android, kind: SaveAssetKind.other);
      expect(droid.routes.single.id, SaveRouteId.downloads);
      for (final p in [ios, droid]) {
        expect(p.routes.where((r) => r.id == SaveRouteId.gallery), isEmpty,
            reason: '矩阵声明不进图库 → 该路整条缺席(B0 skip 短路的正式化)');
      }
    });
  });

  group('runSavePlan — 双路编排(测试功能点 5:失败路互不阻塞)', () {
    test('D1 双主路并发:各持独立副本,Downloads 路删自己的源不反噬图库路', () async {
      final src = await _makeSource(name: 'IMG_0002.livp');
      addTearDown(() => _cleanupSrc(src));
      final paths = <String>[];
      // 用记录件前后插桩拿不到并发时序,直接在 savers 外再包一层记录路径
      final outcomes = await runSavePlan(
        file: src,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.livp),
        savers: PlatformSavers(
          gallery: (f, a) async {
            paths.add(f.path);
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await f.readAsBytes(); // 复刻真机时序:慢一步读,旧共用文件实现必炸
            return const SinkOutcome.ok('图库双存落点');
          },
          downloads: (f) async {
            paths.add(f.path);
            await f.delete(); // saveFile 实证行为:搬运后无条件删源
            return const SinkOutcome.ok('Download/浣花视界/IMG_0002.livp');
          },
          share: (f) async => throw StateError('不该被调用'),
        ),
      );
      expect(paths.toSet().length, 2, reason: '两路文件路径互不相同(独立副本)');
      expect(outcomes.every((o) => o.isOk), isTrue);
      expect(await src.exists(), isTrue, reason: '源文件未被任何一路动过');
    });

    test('单主路免复制:直接用原档(image Android 主路 + 兜底未触发)', () async {
      final src = await _makeSource();
      addTearDown(() => _cleanupSrc(src));
      final rec = RecordingSavers();
      final outcomes = await runSavePlan(
        file: src,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.image),
        savers: rec.savers(),
      );
      expect(outcomes.single.isOk, isTrue);
      expect(rec.downloadsCalls, isEmpty, reason: '主路成功 → 兜底路不执行');
      expect(rec.galleryCalls.single.$1.path, src.path,
          reason: '单主路零复制(B0 遗留优化落地)');
    });

    test('兜底链:图库失败 → Downloads 直写;图库成功 → 兜底不跑', () async {
      final src = await _makeSource();
      addTearDown(() => _cleanupSrc(src));
      final failGallery = RecordingSavers(galleryOk: false);
      final outcomes = await runSavePlan(
        file: src,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.image),
        savers: failGallery.savers(),
      );
      expect(outcomes.length, 2, reason: '主路+兜底路都有结果');
      expect(outcomes[0].isOk, isFalse);
      expect(outcomes[1].route.id, SaveRouteId.downloads);
      expect(outcomes[1].isOk, isTrue);
      expect(failGallery.downloadsCalls.single.path, src.path);

      final okGallery = RecordingSavers();
      final outcomes2 = await runSavePlan(
        file: src,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.image),
        savers: okGallery.savers(),
      );
      expect(outcomes2.length, 1);
      expect(okGallery.downloadsCalls, isEmpty);
    });

    test('iOS livp:图库失败兜底 share;share 路拿原档(串行无竞态)', () async {
      final src = await _makeSource(name: 'IMG_0003.livp');
      addTearDown(() => _cleanupSrc(src));
      final rec = RecordingSavers(galleryOk: false);
      final outcomes = await runSavePlan(
        file: src,
        plan:
            planSaveRoutes(platform: SavePlatform.ios, kind: SaveAssetKind.livp),
        savers: rec.savers(),
      );
      expect(outcomes.last.route.id, SaveRouteId.share);
      expect(outcomes.last.isOk, isTrue);
      expect(rec.shareCalls.single.path, src.path);
    });

    test('全部路失败:返回全部结果(调用方汇总);单路异常兜成失败不外泄', () async {
      final src = await _makeSource();
      addTearDown(() => _cleanupSrc(src));
      final outcomes = await runSavePlan(
        file: src,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.image),
        savers: PlatformSavers(
          gallery: (f, a) async => throw StateError('photo_manager 通道炸了'),
          downloads: (f) async => const SinkOutcome.fail('disk full'),
          share: (f) async => const SinkOutcome.fail('no'),
        ),
      );
      expect(outcomes.every((o) => !o.isOk), isTrue);
      expect(outcomes[0].outcome.detail, contains('photo_manager 通道炸了'));
    });

    test('成功主路副本清理(多主路场景);源不可读 → 两路各自失败', () async {
      final src = await _makeSource();
      addTearDown(() => _cleanupSrc(src));
      final copies = <File>[];
      final outcomes = await runSavePlan(
        file: src,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.livp),
        savers: PlatformSavers(
          gallery: (f, a) async {
            copies.add(f);
            return const SinkOutcome.ok('图库落点');
          },
          downloads: (f) async {
            copies.add(f);
            await f.delete(); // 复刻 saveFile 搬运后删源(独占副本只波及本路)
            return const SinkOutcome.ok('Downloads 落点');
          },
          share: (f) async => const SinkOutcome.fail('no'),
        ),
      );
      expect(outcomes.every((o) => o.isOk), isTrue);
      // 副本清理是 fire-and-forget(.ignore()),Windows 下目录删除偶发延迟,
      // 有界轮询兜住,语义不放宽:终态必须删干净
      var gone = false;
      for (var i = 0; i < 500 && !gone; i++) {
        gone = copies.every((c) => !c.existsSync());
        if (!gone) await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gone, isTrue, reason: '成功路副本连同独占目录清理');

      final missing =
          File('${(await Directory.systemTemp.createTemp('media_save_test')).path}/ghost.jpg');
      addTearDown(() => missing.parent.delete().ignore());
      // 假件须真实读取文件(与真执行件同语义):源不可读才落失败路
      final outcomes2 = await runSavePlan(
        file: missing,
        plan: planSaveRoutes(
            platform: SavePlatform.android, kind: SaveAssetKind.image),
        savers: PlatformSavers(
          gallery: (f, a) async {
            await f.readAsBytes();
            return const SinkOutcome.ok('不该到达');
          },
          downloads: (f) async {
            await f.readAsBytes();
            return const SinkOutcome.ok('不该到达');
          },
          share: (f) async => const SinkOutcome.fail('no'),
        ),
      );
      expect(outcomes2.every((o) => !o.isOk), isTrue, reason: '编排不抛出');
    });
  });

  group('saveSummary / 空间估算与预检(测试功能点 2)', () {
    test('汇总文案:成功路 okText 连接;失败路追加 detail', () {
      final p = planSaveRoutes(
          platform: SavePlatform.android, kind: SaveAssetKind.livp);
      final both = [
        RouteOutcome(
            route: p.routes[0],
            outcome: const SinkOutcome.ok('Pictures/x.jpg')),
        RouteOutcome(route: p.routes[1], outcome: const SinkOutcome.ok('y')),
      ];
      expect(saveSummary(both), '已存入相册、已存入 Download/浣花视界');
      final partial = [
        RouteOutcome(
            route: p.routes[0], outcome: const SinkOutcome.fail('未获相册权限')),
        RouteOutcome(route: p.routes[1], outcome: const SinkOutcome.ok('y')),
      ];
      expect(saveSummary(partial), '已存入 Download/浣花视界;失败:未获相册权限');
      expect(saveSummary(const []), '未保存');
    });

    test('估算:Android livp D1=4×(临时+双路+解包);image=3×;iOS livp=4×',
        () {
      expect(
          estimateRequiredBytes(
              100,
              planSaveRoutes(
                  platform: SavePlatform.android,
                  kind: SaveAssetKind.livp)),
          400);
      expect(
          estimateRequiredBytes(
              100,
              planSaveRoutes(
                  platform: SavePlatform.android,
                  kind: SaveAssetKind.image)),
          300);
      expect(
          estimateRequiredBytes(
              100,
              planSaveRoutes(
                  platform: SavePlatform.ios, kind: SaveAssetKind.livp)),
          400);
      expect(
          estimateRequiredBytes(
              100,
              planSaveRoutes(
                  platform: SavePlatform.android,
                  kind: SaveAssetKind.other)),
          200);
    });

    test('预检边界:null=未知放行;free≤required 不足中止;free>required 放行',
        () {
      expect(checkSpace(null, 100), SpaceVerdict.unknown);
      expect(checkSpace(100, 100), SpaceVerdict.insufficient,
          reason: '相等即不足(保守)');
      expect(checkSpace(99, 100), SpaceVerdict.insufficient);
      expect(checkSpace(101, 100), SpaceVerdict.ok);
    });
  });

  test('baseNameOf:正斜杠/反斜杠/混合分隔符都只取末段(B0 钉子沿用)', () {
    expect(baseNameOf('/data/user/0/pkg/cache/dl_1_IMG.livp'), 'dl_1_IMG.livp');
    expect(baseNameOf(r'C:\Temp\route_x\IMG_0001.jpg'), 'IMG_0001.jpg');
    expect(baseNameOf(r'C:\Temp\route_x/IMG_0001.jpg'), 'IMG_0001.jpg',
        reason: '混合分隔符:单分隔切会把目录名并进文件名(真机竞态修复伴生回归)');
    expect(baseNameOf('plain.bin'), 'plain.bin');
  });
}
