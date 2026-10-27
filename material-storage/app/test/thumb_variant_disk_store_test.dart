/// ThumbDiskStore 变体维度单测(thumb-variant 批 T3,测试功能点 12 §6.12;
/// 契约 §3.7 磁盘段):
/// ① init() 建 `<cache>/thumbs_v2/` 且与旧 `thumbs/` 同级(禁止嵌套);
/// ② init 后旧 `thumbs/` 内 *.bin 被**文件级**清空,非 bin 文件与子目录保留、
///    旧目录本身保留(非递归删目录,一次性迁移);
/// ③ 文件名 `<净化assetId>.<diskTag>.bin`——large 落 `<id>.lg.bin`(默认参数
///    即 large)、small 落 `<id>.s.bin`,非法字符净化沿用既有口径;
/// ④ 同 assetId 不同 variant 互不命中(写 large 读 small 为 miss,字节各自
///    独立,互不覆盖)。
///
/// IO 纪律(仓内已知坑):本文件全部走 plain `test()` 真实 async——真实磁盘
/// IO 在 fakeAsync zone 永不推进(挂死),禁用 testWidgets/fakeAsync。
/// path_provider 经方法通道桩返回临时目录(transfer_store_test 同手法;
/// 通道方法名 `getApplicationCacheDirectory` 与 Dart API 同名)。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/core/thumb_variant.dart';

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

const _cacheDirChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('thumb_variant_disk');
    // 单例防串:清上一用例遗留的注入目录(init 幂等守卫靠 _dir 判空)
    ThumbDiskStore.I.debugAttachDirectory(null);
  });

  tearDown(() {
    ThumbDiskStore.I.debugAttachDirectory(null);
    try {
      base.deleteSync(recursive: true);
    } catch (_) {
      /* 清理失败不影响结果 */
    }
  });

  /// 挂 path_provider 通道桩:getApplicationCacheDirectory → [base].path。
  /// 桩必须在 init() 首次调用前安装(仓内已知坑同款:插件通道初始化一次性)。
  void stubCacheDir() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cacheDirChannel, (call) async {
      if (call.method == 'getApplicationCacheDirectory') return base.path;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cacheDirChannel, null);
    });
  }

  group('init 与 v2 目录(功能点 12①)', () {
    test('init 后 v2 目录为 <cache>/thumbs_v2,不存在则创建', () async {
      stubCacheDir();

      await ThumbDiskStore.I.init();

      final v2 = Directory('${base.path}/thumbs_v2');
      expect(v2.existsSync(), isTrue, reason: 'init 必须创建 <cache>/thumbs_v2');
      expect(v2.path, '${base.path}/thumbs_v2', reason: '目录名固定 thumbs_v2');
    });

    test('v2 与旧 thumbs/ 同级(禁止嵌套)', () async {
      Directory('${base.path}/thumbs').createSync(); // 先有旧目录
      stubCacheDir();

      await ThumbDiskStore.I.init();

      final v2 = Directory('${base.path}/thumbs_v2');
      expect(v2.existsSync(), isTrue, reason: 'v2 建在 <cache>/thumbs_v2');
      expect(Directory('${base.path}/thumbs').existsSync(), isTrue,
          reason: '旧目录保留(同级共存,不删除不重建)');
      expect(
        Directory('${base.path}/thumbs/thumbs_v2').existsSync(),
        isFalse,
        reason: 'v2 不得嵌套进旧 thumbs/ 内(与旧目录同级)',
      );
    });

    test('init 文件级清空旧 thumbs/ 内 *.bin;旧目录本身与非 bin 内容保留',
        () async {
      final legacy = Directory('${base.path}/thumbs')..createSync();
      File('${legacy.path}/old.lg.bin').writeAsBytesSync(_bytes([1]));
      File('${legacy.path}/old.s.bin').writeAsBytesSync(_bytes([2]));
      File('${legacy.path}/keep.txt').writeAsStringSync('not-a-thumb');
      final nested = Directory('${legacy.path}/nested')..createSync();
      File('${nested.path}/deep.bin').writeAsBytesSync(_bytes([3]));

      stubCacheDir();
      await ThumbDiskStore.I.init();

      expect(legacy.existsSync(), isTrue, reason: '旧目录本身保留(非递归删目录)');
      expect(File('${legacy.path}/old.lg.bin').existsSync(), isFalse,
          reason: '旧 *.bin 文件级清除(一次性迁移)');
      expect(File('${legacy.path}/old.s.bin').existsSync(), isFalse,
          reason: '清理不区分旧命名维度的 *.bin');
      expect(File('${legacy.path}/keep.txt').existsSync(), isTrue,
          reason: '非 bin 文件保留');
      expect(File('${nested.path}/deep.bin').existsSync(), isTrue,
          reason: '子目录不递归清除');
      expect(Directory('${base.path}/thumbs_v2').existsSync(), isTrue,
          reason: '清旧失败也不应影响 v2 正常初始化(v2 照常创建)');
    });

    test('init 后写入落在 v2 目录(根目录切换,不误写旧 thumbs/)', () async {
      stubCacheDir();
      await ThumbDiskStore.I.init();

      await ThumbDiskStore.I.write('w1', _bytes([9]), variant: ThumbVariant.small);

      expect(
        File('${base.path}/thumbs_v2/w1.s.bin').existsSync(),
        isTrue,
        reason: 'init 后磁盘根目录为 thumbs_v2',
      );
      expect(
        Directory('${base.path}/thumbs').existsSync(),
        isFalse,
        reason: '不会在新会话重建/误写旧 thumbs/',
      );
    });
  });

  group('variant 文件名与互不命中(功能点 12②③)', () {
    test('文件名 <净化id>.lg.bin / <id>.s.bin;默认参数即 large;非法字符净化',
        () async {
      final dir = Directory('${base.path}/thumbs_v2')..createSync();
      ThumbDiskStore.I.debugAttachDirectory(dir);

      await ThumbDiskStore.I.write('a1', _bytes([1])); // 缺省 variant=large
      await ThumbDiskStore.I.write('a1', _bytes([2]),
          variant: ThumbVariant.small);
      await ThumbDiskStore.I.write('we/ird:id 资产#1', _bytes([3]));

      // Windows 下 listSync 与 dir.path 都是 `\` 分隔,统一归一为 `/` 再比对
      // (仅路径分隔符归一,断言语义不变)
      final dirPath = dir.path.replaceAll('\\', '/');
      final names =
          dir.listSync().map((e) => e.path.replaceAll('\\', '/')).toList()
            ..sort();
      expect(
        names,
        contains('$dirPath/a1.lg.bin'),
        reason: 'large(含缺省)落 <id>.lg.bin(diskTag=lg)',
      );
      expect(
        names,
        contains('$dirPath/a1.s.bin'),
        reason: 'small 落 <id>.s.bin(diskTag=s)',
      );
      expect(
        names,
        contains('$dirPath/weirdid1.lg.bin'),
        reason: 'assetId 净化(仅留 [A-Za-z0-9_-])后拼 diskTag',
      );
      expect(names.length, 3, reason: '每 assetId×variant 恰一个文件,无多余产物');
    });

    test('同 assetId 不同 variant 互不命中:写 large 读 small 为 miss;'
        '字节各自独立互不覆盖', () async {
      final dir = Directory('${base.path}/thumbs_v2')..createSync();
      ThumbDiskStore.I.debugAttachDirectory(dir);
      final largeBytes = _bytes([1, 2, 3]);
      final smallBytes = _bytes([4, 5, 6, 7]);

      await ThumbDiskStore.I.write('x1', largeBytes);
      expect(
        await ThumbDiskStore.I.read('x1', variant: ThumbVariant.small),
        isNull,
        reason: '写 large 后读 small 必须未命中(变体键互不串)',
      );
      expect(
        ThumbDiskStore.I.debugHas('x1', variant: ThumbVariant.small),
        isFalse,
        reason: 'small 文件未落盘',
      );

      await ThumbDiskStore.I.write('x1', smallBytes, variant: ThumbVariant.small);
      expect(
        await ThumbDiskStore.I.read('x1', variant: ThumbVariant.small),
        smallBytes,
        reason: 'small 条目读回自身字节',
      );
      expect(
        await ThumbDiskStore.I.read('x1', variant: ThumbVariant.large),
        largeBytes,
        reason: 'small 写入不覆盖 large 条目',
      );
      expect(
        ThumbDiskStore.I.debugHas('x1', variant: ThumbVariant.large),
        isTrue,
      );
      expect(
        dir.listSync().whereType<File>().length,
        2,
        reason: '两变体各自独立落盘恰好两个文件',
      );
      expect(
        await ThumbDiskStore.I.debugSizeBytes(),
        largeBytes.length + smallBytes.length,
        reason: '总字节对账(两变体并存)',
      );
    });

    test('remove 按 variant 独立:删 small 不影响 large', () async {
      final dir = Directory('${base.path}/thumbs_v2')..createSync();
      ThumbDiskStore.I.debugAttachDirectory(dir);

      await ThumbDiskStore.I.write('x2', _bytes([1]));
      await ThumbDiskStore.I.write('x2', _bytes([2]), variant: ThumbVariant.small);

      await ThumbDiskStore.I.remove('x2', variant: ThumbVariant.small);
      expect(
        await ThumbDiskStore.I.read('x2', variant: ThumbVariant.small),
        isNull,
        reason: 'small 移除生效',
      );
      expect(
        await ThumbDiskStore.I.read('x2', variant: ThumbVariant.large),
        _bytes([1]),
        reason: 'large 文件不受 small 移除波及',
      );
    });
  });
}
