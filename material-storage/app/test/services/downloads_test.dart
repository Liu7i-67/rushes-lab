/// B4 下载编排单测(测试功能点 3/4/5/6):runDownloadJob 进度回传入队、
/// D1 双路共用一次下载、落盘成功删临时、全败保留临时可重试(重新下载+重新
/// 落盘)、空间预检不足中止不半途写坏、livp Android 解包双存、批量 >20 门槛与
/// 逐文件入队;downloadsOutcome null→ok 语义沿用(B0 用例保持)。
/// IO 全注入假件,PC 零平台通道、零网络。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/downloads.dart';
import 'package:ms_app/services/media_save.dart';

Asset _asset(String filename, {int size = 100, String? ct}) =>
    Asset(id: 'a-$filename', filename: filename, sizeBytes: size,
        contentType: ct, createdAt: '2026-10-20T10:00:00Z');

/// 可控成败的假落盘件(记录调用;downloadsOk=false 不删源)。
class FakeSavers {
  FakeSavers({this.galleryOk = true, this.downloadsOk = true});

  bool galleryOk;
  bool downloadsOk;

  final galleryCalls = <GalleryAction>[];
  final downloadsCalls = <File>[];

  PlatformSavers build() => PlatformSavers(
        gallery: (f, a) async {
          galleryCalls.add(a);
          return galleryOk
              ? const SinkOutcome.ok('Pictures/x')
              : const SinkOutcome.fail('未获相册权限(模拟)');
        },
        downloads: (f) async {
          downloadsCalls.add(f);
          return downloadsOk
              ? const SinkOutcome.ok('Download/浣花视界/x')
              : const SinkOutcome.fail('disk full(模拟)');
        },
        share: (f) async => const SinkOutcome.ok('已弹出分享面板'),
      );
}

/// 假 IO 束:link/fetch 记录调用,fetch 落真实临时字节(多主路要复制)。
class FakeIo {
  FakeIo({this.freeBytes = 1 << 40});

  int freeBytes;
  final links = <Asset>[];
  final fetches = <String>[];
  final toasts = <String>[];

  DownloadIo bundle(FakeSavers savers) => DownloadIo(
        link: (a) async {
          links.add(a);
          return 'http://presigned/${a.filename}';
        },
        fetch: ({required url, required savePath, required totalBytes,
          required onProgress, required token}) async {
          fetches.add(savePath);
          final f = File(savePath);
          await f.writeAsBytes(const [9, 9, 9, 9]);
          if (totalBytes > 0) onProgress(totalBytes ~/ 2);
          onProgress(totalBytes);
          return f;
        },
        freeBytes: (_) async => freeBytes,
        tempRoot: () => Directory.systemTemp.createTemp('dl_job_test'),
        savers: savers.build(),
        toast: toasts.add,
      );
}

/// fetch 内取消 token 的 IO(复刻「下载完才发现用户已取消」竞态)。
/// [onToast] 接真实 toast 通路(P2-8:断言取消后不发成功 toast)。
DownloadIo cancelAfterFetchIo(PlatformSavers savers,
        Future<Directory> Function() root,
        {void Function(String message)? onToast}) =>
    DownloadIo(
      link: (a) async => 'http://presigned/x',
      fetch: ({required url, required savePath, required totalBytes,
        required onProgress, required CancelToken token}) async {
        final f = File(savePath);
        await f.writeAsBytes(const [1]);
        token.cancel('用户取消');
        return f;
      },
      freeBytes: (_) async => 1 << 40,
      tempRoot: root,
      savers: savers,
      toast: onToast,
    );

/// 轮询等任务落终态(worker 是真实 async 链,微任务泵不推进真实延时)。
Future<void> _settled(TransferQueue q, String id, {int maxMs = 5000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: maxMs));
  while (DateTime.now().isBefore(deadline)) {
    final t = q.byId(id);
    if (t != null && t.status.isTerminal) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('任务未在时限内落终态');
}

void main() {
  group('downloadsOutcome(B0「null 亦成功」语义沿用,测试功能点 6)', () {
    test('null → ok,detail 提示重名自动加后缀(0.1.3 成功返 null 钉子)', () {
      final out = downloadsOutcome(null);
      expect(out.isOk, isTrue);
      expect(out.detail, contains('Download/浣花视界/'));
      expect(out.detail, contains('成功亦返回 null'));
    });

    test('info 非 null → ok,detail=路径+saveStatus+uri', () {
      final out = downloadsOutcome(SaveInfo(
        name: 'IMG_0001.jpg',
        uri: Uri.parse('content://media/external_primary/downloads/42'),
        saveStatus: SaveStatus.created,
      ));
      expect(out.isOk, isTrue);
      expect(out.detail, contains('IMG_0001.jpg'));
      expect(out.detail, contains('created'));
    });

    test('重名 duplicated 同样映射成功(重名自动加后缀属正常落盘)', () {
      final out = downloadsOutcome(SaveInfo(
        name: 'IMG_0001 (1).jpg',
        uri: Uri.parse('content://media/downloads/43'),
        saveStatus: SaveStatus.duplicated,
      ));
      expect(out.isOk, isTrue);
    });
  });

  group('runDownloadJob 编排(经 TransferQueue 真实入队)', () {
    test('Android livp D1:一次下载、双路落盘(gallery=saveLivpPair + Downloads),'
        '成功删临时,toast 报双去处(测试功能点 5/3)', () async {
      final q = TransferQueue();
      final rec = FakeIo();
      final io = rec.bundle(FakeSavers());
      final id = enqueueDownload(
        asset: _asset('IMG_0001.livp', size: 4, ct: 'application/zip'),
        where: '项目/夹',
        platform: SavePlatform.android,
        queue: q,
        io: io,
      );
      await _settled(q, id);
      expect(rec.links.length, 1, reason: 'D1 双落盘共用一次下载(一次 link+fetch)');
      expect(rec.fetches.length, 1);
      expect(q.byId(id)!.status, TransferStatus.done);
      expect(q.byId(id)!.kind, TransferKind.download);
      expect(q.byId(id)!.doneBytes, 4, reason: '进度回传入队:终态满格');
      expect(await File(rec.fetches.single).exists(), isFalse,
          reason: '落盘成功后删临时文件');
      expect(rec.toasts.single, contains('已存入相册'));
      expect(rec.toasts.single, contains('Download/浣花视界'));
    });

    test('livp Android 双路动作声明经编排落到执行件:gallery 收 saveLivpPair、'
        'downloads 各一次', () async {
      final q = TransferQueue();
      final savers = FakeSavers();
      final rec = FakeIo();
      final id = enqueueDownload(
        asset: _asset('IMG_0002.livp', size: 4, ct: 'application/zip'),
        where: 'w',
        platform: SavePlatform.android,
        queue: q,
        io: rec.bundle(savers),
      );
      await _settled(q, id);
      expect(savers.galleryCalls, [GalleryAction.saveLivpPair],
          reason: 'livp 解包静态图+视频分别存图库(D1①)');
      expect(savers.downloadsCalls.length, 1, reason: '.livp 原档写 Downloads(D1②)');
    });

    test('空间预检不足:中止于下载前(fetch/link 不发),任务失败带文案'
        '(测试功能点 2:不足→中止不半途写坏)', () async {
      final q = TransferQueue();
      final rec = FakeIo()..freeBytes = 10;
      final id = enqueueDownload(
        asset: _asset('a.jpg', size: 100),
        where: 'w',
        platform: SavePlatform.android,
        queue: q,
        io: rec.bundle(FakeSavers()),
      );
      await _settled(q, id);
      final task = q.byId(id)!;
      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('空间不足'));
      expect(rec.links, isEmpty, reason: '预检在 download-link 之前');
      expect(rec.fetches, isEmpty, reason: '不足即中止,不半途写坏');
    });

    test('全路失败:临时保留供取证、任务失败带分路错误;重试=重新下载+重新落盘'
        '(测试功能点 3)', () async {
      final q = TransferQueue();
      // image android:图库主路败 → Downloads 兜底路也败 → 全败
      final savers = FakeSavers()
        ..galleryOk = false
        ..downloadsOk = false;
      final rec = FakeIo();
      final id = enqueueDownload(
        asset: _asset('b.jpg', size: 4),
        where: 'w',
        platform: SavePlatform.android,
        queue: q,
        io: rec.bundle(savers),
      );
      await _settled(q, id);
      final task = q.byId(id)!;
      expect(task.status, TransferStatus.failed);
      expect(task.error, contains('保存失败'));
      expect(task.error, contains('disk full'));
      expect(await File(rec.fetches.single).exists(), isTrue,
          reason: '全败保留临时供取证');

      // 重试:同 worker 从头来(重新下载+重新落盘),这次放行
      savers.galleryOk = true;
      savers.downloadsOk = true;
      final newId = q.retry(id)!;
      expect(newId, isNot(id));
      await _settled(q, newId);
      expect(q.byId(newId)!.status, TransferStatus.done);
      expect(rec.fetches.length, 2, reason: '重试=重新下载');
      expect(rec.links.length, 2);
      expect(await File(rec.fetches.last).exists(), isFalse,
          reason: '重试成功后临时删除');
      expect(await File(rec.fetches.first).exists(), isTrue,
          reason: '首败临时仍保留');
    });

    test('部分成功(图库 ok、Downloads 败,D1 双主路):任务 done、toast 明说失败路;'
        '互不阻塞', () async {
      final q = TransferQueue();
      // livp D1:两路无条件并发——图库败不拖累 Downloads,反之亦然;
      // 任一路成功即 done,失败路文案进 toast
      final savers = FakeSavers()..downloadsOk = false;
      final rec = FakeIo();
      final id = enqueueDownload(
        asset: _asset('c.livp', size: 4, ct: 'application/zip'),
        where: 'w',
        platform: SavePlatform.android,
        queue: q,
        io: rec.bundle(savers),
      );
      await _settled(q, id);
      expect(q.byId(id)!.status, TransferStatus.done,
          reason: '任一路成功即完成;失败路文案进 toast,不阻塞成功路');
      expect(rec.toasts.single, contains('已存入相册'));
      expect(rec.toasts.single, contains('失败'));
      expect(rec.toasts.single, contains('disk full'));
    });

    test('下载完成后才取消:不再落盘、临时即删(P2-2)、不发 toast(取消竞态防护)',
        () async {
      final q = TransferQueue();
      final savers = FakeSavers();
      final toasts = <String>[];
      // 独占临时根:断言取消后目录已清空(下载临时被补删,不留垃圾)
      final root = await Directory.systemTemp.createTemp('dl_cancel');
      addTearDown(() => root.delete(recursive: true).ignore());
      final id = enqueueDownload(
        asset: _asset('d.jpg', size: 4),
        where: 'w',
        platform: SavePlatform.android,
        queue: q,
        io: cancelAfterFetchIo(savers.build(), () async => root,
            onToast: toasts.add),
      );
      await _settled(q, id);
      expect(q.byId(id)!.status, TransferStatus.done);
      expect(savers.galleryCalls, isEmpty, reason: '已取消 → 不再落盘');
      expect(savers.downloadsCalls, isEmpty);
      expect(toasts, isEmpty, reason: '已取消 → 不发成功 toast(P2-8 真实束断言)');
      expect(root.listSync(), isEmpty,
          reason: '取消路径补删下载临时(P2-2),tempRoot 不留残留');
    });
  });

  group('批量下载(测试功能点 4:>20 门槛、逐文件入队)', () {
    test('needsBatchConfirm 边界:>20 才确认(桌面 web 同款)', () {
      expect(needsBatchConfirm(20), isFalse);
      expect(needsBatchConfirm(21), isTrue);
      expect(kBatchDownloadConfirmMax, 20);
    });

    test('enqueueDownloads 逐文件入队:全成 (n,0)', () async {
      final q = TransferQueue(concurrency: 1);
      final rec = FakeIo();
      final (enq, skip) = await enqueueDownloads(
        [_asset('1.jpg'), _asset('2.mov'), _asset('3.pdf')],
        where: '项目/夹',
        platform: SavePlatform.android,
        queue: q,
        io: rec.bundle(FakeSavers()),
      );
      expect((enq, skip), (3, 0));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) &&
          q.tasks.any((t) => !t.status.isTerminal)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(q.tasks.every((t) => t.status == TransferStatus.done), isTrue);
      expect(rec.fetches.length, 3, reason: '逐文件入队,每个各下载各落盘');
    });

    test('单点入队失败不中断整批(口径同上传 enqueueBatch)', () async {
      final q = _ThrowOnEnqueue();
      final (enq, skip) = await enqueueDownloads(
        [_asset('ok1.jpg'), _asset('boom.bin'), _asset('ok2.jpg')],
        where: 'w',
        platform: SavePlatform.android,
        queue: q,
        io: FakeIo().bundle(FakeSavers()),
      );
      expect((enq, skip), (2, 1));
    });
  });
}

class _ThrowOnEnqueue extends TransferQueue {
  @override
  String enqueue(TransferRequest req) {
    if (req.filename == 'boom.bin') throw StateError('入队炸了(模拟)');
    return super.enqueue(req);
  }
}
