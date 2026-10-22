/// ThumbDiskStore 单测(app-polish-3 测试功能点 2,B1):落盘字节往返、
/// 未写回 null、clear 清空、多文件写入后最新文件仍可读(容量上限 150MB
/// 不可注入,LRU 断言降级为「多文件写入后仍能读回」+ debugSizeBytes 对账)、
/// IO 异常一律吞掉不抛(目录不存在 read/write/clear 均静默)、文件名非法
/// 字符清洗与非 ASCII 回退 hashCode 命名。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/thumb_disk_store.dart';

Directory _tmp() => Directory.systemTemp.createTempSync('thumb_disk_test');

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

void main() {
  late Directory dir;

  setUp(() {
    dir = _tmp();
    ThumbDiskStore.I.debugAttachDirectory(dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {/* 清理失败不影响结果 */}
  });

  test('app-polish-3 功能点 2:write 后 read 返回相同字节(落盘往返)', () async {
    final payload = _bytes([1, 2, 3, 0xFF, 0x00, 42]);
    await ThumbDiskStore.I.write('a1', payload);

    final got = await ThumbDiskStore.I.read('a1');
    expect(got, isNotNull, reason: '写入后应能读回位图字节');
    expect(got, payload, reason: '读回字节与写入字节逐位一致(原子写不截断)');
  });

  test('app-polish-3 功能点 2:未写过 → read 返回 null(走网络分支)', () async {
    expect(await ThumbDiskStore.I.read('never-written'), isNull,
        reason: '磁盘未命中必须回 null,由 ThumbnailImage 走签 URL 下载');
  });

  test('app-polish-3 功能点 2:clear 后 read 返回 null(登出清空语义)', () async {
    await ThumbDiskStore.I.write('a1', _bytes([7, 8, 9]));
    expect(await ThumbDiskStore.I.read('a1'), isNotNull, reason: '前置:已写入');

    await ThumbDiskStore.I.clear();

    expect(await ThumbDiskStore.I.read('a1'), isNull,
        reason: '登出钩子 clear 后缩略图(含用户素材)必须清空');
    expect(await ThumbDiskStore.I.debugSizeBytes(), 0,
        reason: 'clear 后缓存总字节归零');
  });

  test('app-polish-3 功能点 2:多文件写入后仍能读回最新文件;'
      'debugSizeBytes 与写入总量对账(容量不可注入,LRU 断言降级)', () async {
    final a = _bytes(List.generate(64, (i) => i));
    final b = _bytes(List.generate(128, (i) => 255 - i));
    final c = _bytes([3, 1, 4, 1, 5, 9, 2, 6]);
    await ThumbDiskStore.I.write('old-a', a);
    await ThumbDiskStore.I.write('old-b', b);
    await ThumbDiskStore.I.write('newest-c', c);

    expect(await ThumbDiskStore.I.read('newest-c'), c,
        reason: '最新写入的文件必须完好可读(超限逐出不误删新文件)');
    expect(await ThumbDiskStore.I.read('old-a'), a, reason: '未超容量不逐出');
    expect(await ThumbDiskStore.I.read('old-b'), b);

    expect(await ThumbDiskStore.I.debugSizeBytes(), a.length + b.length + c.length,
        reason: 'debugSizeBytes 与落盘字节总量一致');
  });

  test('app-polish-3 功能点 2:IO 异常不抛——目录不存在时 read 回 null、'
      'write/clear 静默无异常(降级路径,widget 环境同语义)', () async {
    final missing = Directory('${dir.path}/nope/never_created');
    ThumbDiskStore.I.debugAttachDirectory(missing);

    expect(await ThumbDiskStore.I.read('a1'), isNull,
        reason: '目录不可用时 read 必须回 null,不得向 UI 抛异常');
    await ThumbDiskStore.I.write('a1', _bytes([1]));
    await ThumbDiskStore.I.clear();
    expect(await ThumbDiskStore.I.debugSizeBytes(), 0,
        reason: '全部 IO 路径静默降级,总字节按 0 报');

    // 重新挂健康目录后恢复可用(降级不影响后续生命周期)
    ThumbDiskStore.I.debugAttachDirectory(dir);
    await ThumbDiskStore.I.write('a1', _bytes([9]));
    expect(await ThumbDiskStore.I.read('a1'), _bytes([9]),
        reason: '重挂目录后写入/读取恢复正常');
  });

  test('app-polish-3 功能点 2:文件名清洗——非法字符丢弃,同 id 往返一致;'
      '全非法 id 回退 hashCode 命名仍可往返', () async {
    await ThumbDiskStore.I.write('we/ird:id 资产#1', _bytes([1, 1, 2]));
    expect(dir.listSync().whereType<File>().length, 1,
        reason: '非法字符被清洗,落盘恰好一个文件(不产生路径穿越/乱名)');

    final roundtrip = await ThumbDiskStore.I.read('we/ird:id 资产#1');
    expect(roundtrip, _bytes([1, 1, 2]), reason: '同 id 清洗后命中同一文件');

    await ThumbDiskStore.I.write('资源/夹', _bytes([5, 6]));
    expect(await ThumbDiskStore.I.read('资源/夹'), _bytes([5, 6]),
        reason: '清洗后为空的 id 回退 hashCode 命名,写入不静默丢失');
    expect(dir.listSync().whereType<File>().length, 2);
  });
}
