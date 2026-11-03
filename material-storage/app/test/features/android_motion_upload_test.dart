/// Android motion photo 上传链路用例(方案 §7 第 5 条全集;§5.3 注入缝,
/// 假件注入模式沿 upload_batch_report_test / transfer_queue_test 既有形状):
/// 入队侧——预筛命中→motion 入队(filename='{base}.livp'、入队秒回不打包)/
/// 未命中、超 150MB、probe 抛错→普通轨原样(逐项捕获语义不变);
/// worker 侧——复验命中以复验新 plan 打包(弃入队 plan)/复验命中但 >150MB→
/// {base}.jpg+image/jpeg 降级且任务算成功/复验 null 文件在→降级普通轨且任务
/// 成功/文件不存在→任务失败/打包 STORED(zip 条目 {base}.jpg+{base}.mp4、
/// contentType=application/zip)/终态(成功/失败/取消)一律删临时/retry 从头
/// 重打包/上传异常=任务失败/TOCTOU 实际 size≠入队 totalBytes 进度 clamp 不
/// 越界/并发两任务临时 livp 路径互不相同。
///
/// 包 A(lib/services/motion_photo.dart,§5.1)已落地;本文件 MotionPhotoPlan
/// 构造收敛在 planOf 单点,后续形异只改该处。
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/assets/android_motion_upload.dart';
import 'package:ms_app/features/assets/android_motion_worker.dart';
import 'package:ms_app/services/motion_photo.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 包 A 已落地(motion_photo.dart):MotionPhotoPlan 构造为位置参数,planOf
/// 仍为唯一构造单点,后续形异只改该处。
MotionPhotoPlan planOf(int start, int end, int size) =>
    MotionPhotoPlan('gcontainer', start, end, size);

AssetEntity entity() => AssetEntity(
  id: 'asset-7',
  typeInt: 1,
  width: 100,
  height: 100,
  title: 'IMG_1.JPG',
);

/// 排空微任务(worker 的 await 链落地,同 transfer_queue_test 惯例)。
Future<void> drain([int ticks = 8]) async {
  for (var i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  // ── 入队侧:tryAndroidMotionPhoto(§5.3 分支)──────────────────────────

  test('入队:预筛命中→motion 入队(base/srcPath/plan/srcBytes 正确)且接管', () async {
    final probePaths = <String>[];
    final enqueues = <String, Object?>{};
    final taken = await tryAndroidMotionPhoto(
      entity(),
      'f1',
      '项目A/夹B',
      '/src/IMG_1.JPG', // 大写扩展名:extOf 归一小写后命中
      'IMG_1.JPG',
      isAndroid: true,
      sizeOf: (_) async => 1000,
      probe: (p) async {
        probePaths.add(p);
        return planOf(10, 990, 1000);
      },
      enqueue:
          ({
            required base,
            required srcPath,
            required plan,
            required srcBytes,
          }) async {
            enqueues
              ..['base'] = base
              ..['srcPath'] = srcPath
              ..['plan'] = plan
              ..['srcBytes'] = srcBytes;
            return 't1';
          },
    );
    expect(taken, isTrue, reason: '接管:调用方 return,不再落普通轨');
    expect(probePaths, ['/src/IMG_1.JPG']);
    expect(enqueues['base'], 'IMG_1', reason: '基名取解析名去扩展名');
    expect(enqueues['srcPath'], '/src/IMG_1.JPG');
    expect((enqueues['plan'] as MotionPhotoPlan).videoStart, 10);
    expect(enqueues['srcBytes'], 1000, reason: 'totalBytes 以原档大小入队');
  });

  test('入队壳:显示名 {base}.livp、totalBytes=原档;入队秒回不打包,worker 执行时'
      '才打包上传(16MB 流式轨 contentType=application/zip),终态删临时', () async {
    final probeGate = Completer<MotionPhotoPlan?>();
    final packGate = Completer<String>();
    final packPlans = <MotionPhotoPlan>[];
    final uploads = <({String filename, String path, String contentType})>[];
    final deletes = <String>[];
    final io = MotionPhotoWorkerIo(
      probe: (_) => probeGate.future,
      sizeOf: (_) async => 1234,
      pack: ({required srcPath, required plan, required base}) {
        packPlans.add(plan);
        return packGate.future;
      },
      upload:
          ({
            required folderId,
            required filename,
            required path,
            required contentType,
            cancelToken,
            onProgress,
          }) async {
            uploads.add((
              filename: filename,
              path: path,
              contentType: contentType,
            ));
            onProgress?.call(10, 10);
          },
      deleteTemp: (p) async => deletes.add(p),
    );
    final id = enqueueMotionPhotoUpload(
      folderId: 'f1',
      where: '项目A/夹B',
      base: 'IMG_9',
      srcPath: '/src/IMG_9.jpg',
      plan: planOf(10, 1230, 1234),
      srcBytes: 1234,
      io: io,
    );
    final task = TransferQueue.I.byId(id)!;
    expect(task.filename, 'IMG_9.livp', reason: '显示名 {base}.livp');
    expect(task.totalBytes, 1234);
    expect(task.kind, TransferKind.upload);
    expect(packPlans, isEmpty, reason: '入队秒回不打包(打包延迟到 worker)');
    probeGate.complete(planOf(10, 1230, 1234)); // 复验命中(新 plan 实例)
    await drain();
    expect(packPlans, hasLength(1), reason: 'worker 执行时才打包');
    packGate.complete('/tmp/motion_pack_fake.livp');
    await drain();
    expect(uploads.single.filename, 'IMG_9.livp');
    expect(
      uploads.single.contentType,
      'application/zip',
      reason: '.livp 由 uploadContentTypeFor 定=zip',
    );
    expect(uploads.single.path, '/tmp/motion_pack_fake.livp');
    await drain();
    expect(task.status, TransferStatus.done);
    expect(task.doneBytes, 1234);
    expect(deletes, ['/tmp/motion_pack_fake.livp'], reason: '成功终态删临时');
    TransferQueue.I.remove(id);
  });

  test('入队:probe 未命中→返回 false(调用方落普通轨原样),不 motion 入队', () async {
    var enqueued = false;
    final taken = await tryAndroidMotionPhoto(
      entity(),
      'f1',
      'w',
      '/src/a.jpg',
      'a.jpg',
      isAndroid: true,
      sizeOf: (_) async => 100,
      probe: (_) async => null,
      enqueue:
          ({
            required base,
            required srcPath,
            required plan,
            required srcBytes,
          }) async {
            enqueued = true;
            return 't';
          },
    );
    expect(taken, isFalse);
    expect(enqueued, isFalse);
  });

  test('入队:超 150MB → 返回 false,且大小闸门前置不白付预筛(probe 未调)', () async {
    var probeCalls = 0;
    final taken = await tryAndroidMotionPhoto(
      entity(),
      'f1',
      'w',
      '/src/big.jpg',
      'big.jpg',
      isAndroid: true,
      sizeOf: (_) async => kMotionPhotoMaxBytes + 1,
      probe: (_) async {
        probeCalls += 1;
        return planOf(1, 2, 3);
      },
      enqueue: ({
        required base,
        required srcPath,
        required plan,
        required srcBytes,
      }) async => 't',
    );
    expect(taken, isFalse);
    expect(probeCalls, 0, reason: '先查长度再付预筛');
  });

  test('入队:probe 抛错 → 视同未命中落普通轨原样(整项不计跳过,逐项捕获'
      '语义不变)', () async {
    var enqueued = false;
    final taken = await tryAndroidMotionPhoto(
      entity(),
      'f1',
      'w',
      '/src/a.jpg',
      'a.jpg',
      isAndroid: true,
      sizeOf: (_) async => 100,
      probe: (_) async => throw StateError('probe io boom'),
      enqueue:
          ({
            required base,
            required srcPath,
            required plan,
            required srcBytes,
          }) async {
            enqueued = true;
            return 't';
          },
    );
    expect(taken, isFalse, reason: '预筛 IO 异常不得把整项吞掉不上传(§7 第 5 条)');
    expect(enqueued, isFalse);
  });

  test('入队:非 jpg/jpeg 扩展名 → false 且零 IO;非 Android → false 零 IO', () async {
    var ioCalls = 0;
    Future<int> sizeOf(String _) async {
      ioCalls += 1;
      return 1;
    }

    Future<MotionPhotoPlan?> probe(String _) async {
      ioCalls += 1;
      return planOf(1, 2, 3);
    }

    final png = await tryAndroidMotionPhoto(
      entity(),
      'f1',
      'w',
      '/src/x.png',
      'x.png',
      isAndroid: true,
      sizeOf: sizeOf,
      probe: probe,
      enqueue: ({
        required base,
        required srcPath,
        required plan,
        required srcBytes,
      }) async => 't',
    );
    final notAndroid = await tryAndroidMotionPhoto(
      entity(),
      'f1',
      'w',
      '/src/x.jpg',
      'x.jpg',
      isAndroid: false,
      sizeOf: sizeOf,
      probe: probe,
      enqueue: ({
        required base,
        required srcPath,
        required plan,
        required srcBytes,
      }) async => 't',
    );
    expect(png, isFalse);
    expect(notAndroid, isFalse, reason: '只做格式识别,平台门外零 IO');
    expect(ioCalls, 0);
  });

  // ── worker 侧:runMotionPhotoWorker(§5.3 全流程)─────────────────────

  test('worker:复验命中→以复验新 plan 打包(弃入队 plan),上传 {base}.livp,'
      '成功终态删临时', () async {
    final rePlan = planOf(100, 200, 300);
    final packs = <MotionPhotoPlan>[];
    final uploads = <({String filename, String path, String contentType})>[];
    final deletes = <String>[];
    await runMotionPhotoWorker(
      (_) {},
      CancelToken(),
      folderId: 'f1',
      where: 'w',
      base: 'IMG_8',
      srcPath: '/src/p.jpg',
      enqueuePlan: planOf(10, 20, 30), // 入队 plan,应被弃用
      totalBytes: 30,
      io: MotionPhotoWorkerIo(
        probe: (_) async => rePlan,
        sizeOf: (_) async => 300,
        pack: ({required srcPath, required plan, required base}) async {
          packs.add(plan);
          return '/t/x.livp';
        },
        upload:
            ({
              required folderId,
              required filename,
              required path,
              required contentType,
              cancelToken,
              onProgress,
            }) async {
              uploads.add((
                filename: filename,
                path: path,
                contentType: contentType,
              ));
            },
        deleteTemp: (p) async => deletes.add(p),
      ),
    );
    expect(
      packs.single.videoStart,
      100,
      reason:
          '以复验新 plan 打包(弃入队 plan:'
          '旧 plan 拆分会产出错位产物=静默坏数据)',
    );
    expect(uploads.single.filename, 'IMG_8.livp');
    expect(uploads.single.contentType, 'application/zip');
    expect(uploads.single.path, '/t/x.livp');
    expect(deletes, ['/t/x.livp']);
  });

  test('worker:复验命中但 >150MB → 降级普通轨({base}.jpg/image/jpeg 原档)'
      '且任务算成功,不打包不建临时', () async {
    final uploads = <({String filename, String path, String contentType})>[];
    var packCalls = 0;
    final deletes = <String>[];
    await runMotionPhotoWorker(
      (_) {},
      CancelToken(),
      folderId: 'f1',
      where: 'w',
      base: 'IMG_8',
      srcPath: '/src/swap.jpg',
      enqueuePlan: planOf(10, 20, 30),
      totalBytes: 30,
      io: MotionPhotoWorkerIo(
        probe: (_) async => planOf(10, 20, 30),
        sizeOf: (_) async => kMotionPhotoMaxBytes + 1,
        pack: ({required srcPath, required plan, required base}) async {
          packCalls += 1;
          return '/t/never.livp';
        },
        upload:
            ({
              required folderId,
              required filename,
              required path,
              required contentType,
              cancelToken,
              onProgress,
            }) async {
              uploads.add((
                filename: filename,
                path: path,
                contentType: contentType,
              ));
            },
        deleteTemp: (p) async => deletes.add(p),
      ),
    );
    expect(uploads.single.filename, 'IMG_8.jpg');
    expect(uploads.single.contentType, 'image/jpeg');
    expect(uploads.single.path, '/src/swap.jpg', reason: '直传原档');
    expect(packCalls, 0, reason: '超限不打包');
    expect(deletes, isEmpty, reason: '未建临时无可删');
  });

  test('worker:复验 null 文件在 → 降级普通轨直传原档且任务算成功', () async {
    final dir = await Directory.systemTemp.createTemp('motion_w_null');
    final src = File('${dir.path}/IMG_2.jpg');
    await src.writeAsBytes(<int>[1, 2, 3]);
    final uploads = <({String filename, String path, String contentType})>[];
    var packCalls = 0;
    try {
      await runMotionPhotoWorker(
        (_) {},
        CancelToken(),
        folderId: 'f1',
        where: 'w',
        base: 'IMG_2',
        srcPath: src.path,
        enqueuePlan: planOf(1, 2, 3),
        totalBytes: 3,
        io: MotionPhotoWorkerIo(
          probe: (_) async => null,
          sizeOf: (_) async => 3,
          pack: ({required srcPath, required plan, required base}) async {
            packCalls += 1;
            return '/t/never.livp';
          },
          upload:
              ({
                required folderId,
                required filename,
                required path,
                required contentType,
                cancelToken,
                onProgress,
              }) async {
                uploads.add((
                  filename: filename,
                  path: path,
                  contentType: contentType,
                ));
              },
          deleteTemp: (p) async {},
        ),
      );
    } finally {
      await dir.delete(recursive: true);
    }
    expect(uploads.single.filename, 'IMG_2.jpg');
    expect(uploads.single.contentType, 'image/jpeg');
    expect(uploads.single.path, src.path);
    expect(packCalls, 0);
  });

  test('worker:文件不存在 → 任务失败(文案「原文件已不存在」),零上传零删', () async {
    final dir = await Directory.systemTemp.createTemp('motion_w_gone');
    final missing = '${dir.path}/missing.jpg';
    var uploaded = false;
    try {
      await expectLater(
        runMotionPhotoWorker(
          (_) {},
          CancelToken(),
          folderId: 'f1',
          where: 'w',
          base: 'IMG_3',
          srcPath: missing,
          enqueuePlan: planOf(1, 2, 3),
          totalBytes: 3,
          io: MotionPhotoWorkerIo(
            probe: (_) async => null,
            sizeOf: (_) async => 3,
            pack: ({required srcPath, required plan, required base}) async =>
                '/t/never.livp',
            upload:
                ({
                  required folderId,
                  required filename,
                  required path,
                  required contentType,
                  cancelToken,
                  onProgress,
                }) async {
                  uploaded = true;
                },
            deleteTemp: (p) async {},
          ),
        ),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '原文件已不存在'),
        ),
      );
    } finally {
      await dir.delete(recursive: true);
    }
    expect(uploaded, isFalse);
  });

  test('打包真身:STORED(zip 本地头 method=0)、条目 {base}.jpg+{base}.mp4、'
      '内容原样、临时名 motion_pack_*.livp', () async {
    final dir = await Directory.systemTemp.createTemp('motion_pack_test');
    final jpeg = <int>[0xFF, 0xD8, ...List.generate(48, (i) => i & 0xFF)];
    final mp4 = <int>[
      0x66, 0x74, 0x79, 0x70, // 'ftyp'
      ...List.generate(36, (i) => i & 0xFF),
    ];
    final src = File('${dir.path}/src.jpg');
    await src.writeAsBytes(<int>[...jpeg, ...mp4]);
    try {
      final out = await packMotionPhotoLivpInDir(
        srcPath: src.path,
        plan: planOf(
          jpeg.length,
          jpeg.length + mp4.length,
          jpeg.length + mp4.length,
        ),
        base: 'IMG_7',
        dirPath: dir.path,
      );
      final name = out.split('/').last;
      expect(name.startsWith('motion_pack_'), isTrue, reason: '临时名前缀');
      expect(name.endsWith('.livp'), isTrue);
      final bytes = await File(out).readAsBytes();
      final arc = ZipDecoder().decodeBytes(bytes);
      final files = arc.files.where((f) => f.isFile).toList();
      expect(files.map((f) => f.name).toList(), ['IMG_7.jpg', 'IMG_7.mp4']);
      expect(
        files[0].content as List<int>,
        jpeg,
        reason: '主图=原档截断到 videoStart',
      );
      expect(
        files[1].content as List<int>,
        mp4,
        reason: '视频=[videoStart,videoEnd)',
      );
      // STORED:zip 本地文件头(PK\x03\x04)offset+8 的 compression method==0
      for (var i = 0; i + 10 <= bytes.length; i++) {
        if (bytes[i] == 0x50 &&
            bytes[i + 1] == 0x4B &&
            bytes[i + 2] == 0x03 &&
            bytes[i + 3] == 0x04) {
          expect(
            bytes[i + 8] + (bytes[i + 9] << 8),
            0,
            reason: '本地头 @$i 必须 STORED(0),jpg/mp4 已压缩不付 deflate',
          );
        }
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('并发两任务临时 livp 路径互不相同(唯一命名断言)', () async {
    final dir = await Directory.systemTemp.createTemp('motion_pack_conc');
    final src = File('${dir.path}/src.jpg');
    await src.writeAsBytes(List.generate(64, (i) => i & 0xFF));
    try {
      final paths = await Future.wait([
        packMotionPhotoLivpInDir(
          srcPath: src.path,
          plan: planOf(32, 64, 64),
          base: 'IMG_5',
          dirPath: dir.path,
        ),
        packMotionPhotoLivpInDir(
          srcPath: src.path,
          plan: planOf(32, 64, 64),
          base: 'IMG_5',
          dirPath: dir.path,
        ),
      ]);
      expect(
        paths[0] != paths[1],
        isTrue,
        reason: '并发 2 下同名互踩会把另一任务的 zip 静默传上去,§5.3',
      );
      expect(await File(paths[0]).exists(), isTrue);
      expect(await File(paths[1]).exists(), isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('终态一律删临时 + retry 从头重打包:上传失败→任务失败且删临时;'
      'retry 重跑→重新打包(两次),新临时同样在终态删除', () async {
    final deletes = <String>[];
    var packCalls = 0;
    var failUpload = true;
    Future<void> run() => runMotionPhotoWorker(
      (_) {},
      CancelToken(),
      folderId: 'f1',
      where: 'w',
      base: 'IMG_4',
      srcPath: '/src/p.jpg',
      enqueuePlan: planOf(1, 2, 3),
      totalBytes: 3,
      io: MotionPhotoWorkerIo(
        probe: (_) async => planOf(1, 2, 3),
        sizeOf: (_) async => 3,
        pack: ({required srcPath, required plan, required base}) async {
          packCalls += 1;
          return '/t/run$packCalls.livp';
        },
        upload:
            ({
              required folderId,
              required filename,
              required path,
              required contentType,
              cancelToken,
              onProgress,
            }) async {
              if (failUpload) {
                throw DioException(
                  requestOptions: RequestOptions(path: 'upload'),
                );
              }
            },
        deleteTemp: (p) async => deletes.add(p),
      ),
    );
    await expectLater(run(), throwsA(anything), reason: '上传异常=任务失败外溢');
    expect(deletes, ['/t/run1.livp'], reason: '失败终态也删临时');
    failUpload = false;
    await run(); // retry=同描述从头重跑 worker:重新复验+重新打包
    expect(packCalls, 2, reason: 'retry 从头重打包,非续传');
    expect(deletes, ['/t/run1.livp', '/t/run2.livp']);
  });

  test('取消:token 已取消→上传假件抛 abort,任务失败外溢且终态删临时', () async {
    final token = CancelToken()..cancel('用户取消');
    final deletes = <String>[];
    await expectLater(
      runMotionPhotoWorker(
        (_) {},
        token,
        folderId: 'f1',
        where: 'w',
        base: 'IMG_4',
        srcPath: '/src/p.jpg',
        enqueuePlan: planOf(1, 2, 3),
        totalBytes: 3,
        io: MotionPhotoWorkerIo(
          probe: (_) async => planOf(1, 2, 3),
          sizeOf: (_) async => 3,
          pack: ({required srcPath, required plan, required base}) async =>
              '/t/c.livp',
          upload:
              ({
                required folderId,
                required filename,
                required path,
                required contentType,
                cancelToken,
                onProgress,
              }) async {
                if (cancelToken?.isCancelled ?? false) {
                  throw cancelToken!.cancelError ??
                      DioException(requestOptions: RequestOptions(path: 'x'));
                }
              },
          deleteTemp: (p) async => deletes.add(p),
        ),
      ),
      throwsA(anything),
    );
    expect(deletes, ['/t/c.livp'], reason: '取消终态删临时(retry 从头重打包)');
  });

  test('worker:打包失败 → 任务失败外溢(AppLog 打点),上传不发生、无临时可删', () async {
    var uploaded = false;
    var deleted = false;
    await expectLater(
      runMotionPhotoWorker(
        (_) {},
        CancelToken(),
        folderId: 'f1',
        where: 'w',
        base: 'IMG_6',
        srcPath: '/src/p.jpg',
        enqueuePlan: planOf(1, 2, 3),
        totalBytes: 3,
        io: MotionPhotoWorkerIo(
          probe: (_) async => planOf(1, 2, 3),
          sizeOf: (_) async => 3,
          pack: ({required srcPath, required plan, required base}) async =>
              throw StateError('zip boom'),
          upload:
              ({
                required folderId,
                required filename,
                required path,
                required contentType,
                cancelToken,
                onProgress,
              }) async {
                uploaded = true;
              },
          deleteTemp: (p) async => deleted = true,
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(uploaded, isFalse);
    expect(deleted, isFalse, reason: '打包抛错即无临时路径,无可删');
  });

  test('TOCTOU 后实际 size≠入队 totalBytes:进度按实际 size 归一并 clamp '
      '不越界', () async {
    final seen = <int>[];
    await runMotionPhotoWorker(
      seen.add,
      CancelToken(),
      folderId: 'f1',
      where: 'w',
      base: 'IMG_4',
      srcPath: '/src/p.jpg',
      enqueuePlan: planOf(1, 2, 3),
      totalBytes: 1000, // 入队时原档 1000B
      io: MotionPhotoWorkerIo(
        probe: (_) async => planOf(1, 2, 3),
        sizeOf: (_) async => 1000, // 复验后实际 1000B
        pack: ({required srcPath, required plan, required base}) async =>
            '/t/p.livp',
        upload:
            ({
              required folderId,
              required filename,
              required path,
              required contentType,
              cancelToken,
              onProgress,
            }) async {
              onProgress?.call(500, 2000); // 流式轨按实际上传文件字节回报
              onProgress?.call(2000, 2000);
            },
        deleteTemp: (p) async {},
      ),
    );
    expect(
      seen,
      [250, 1000],
      reason:
          '500/2000 归一到 250;终值 clamp 到入队 '
          'totalBytes=1000,不越界',
    );
  });

  test('进度归一纯函数:total/normalize 非正值→0;normalize>入队时 clamp', () {
    expect(mapMotionProgress(2000, 2000, 1000, 1000), 1000);
    expect(mapMotionProgress(1000, 2000, 1000, 1000), 500);
    expect(mapMotionProgress(10, 0, 1000, 1000), 0, reason: 'total 非正值→0');
    expect(mapMotionProgress(10, 10, 0, 1000), 0, reason: 'normalize 非正值→0');
    expect(
      mapMotionProgress(99, 100, 5000, 100),
      100,
      reason: '归一值(4950)>入队 totalBytes → clamp',
    );
  });
}
