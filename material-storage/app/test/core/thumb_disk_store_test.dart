/// ThumbDiskStore 单测(app-polish-3 测试功能点 2,B1):落盘字节往返、
/// 未写回 null、clear 清空、多文件写入后最新文件仍可读(容量上限 150MB
/// 不可注入,LRU 断言降级为「多文件写入后仍能读回」+ debugSizeBytes 对账)、
/// IO 异常一律吞掉不抛(目录不存在 read/write/clear 均静默)、文件名非法
/// 字符清洗与非 ASCII 回退 hashCode 命名。
/// storm-fix 增量(W1 #9):代际 write/remove、clear 期间 _clearing、
/// 写闸/读闸注入与串行互斥。
library;

import 'dart:async';
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
    } catch (_) {
      /* 清理失败不影响结果 */
    }
  });

  test('app-polish-3 功能点 2:write 后 read 返回相同字节(落盘往返)', () async {
    final payload = _bytes([1, 2, 3, 0xFF, 0x00, 42]);
    await ThumbDiskStore.I.write('a1', payload);

    final got = await ThumbDiskStore.I.read('a1');
    expect(got, isNotNull, reason: '写入后应能读回位图字节');
    expect(got, payload, reason: '读回字节与写入字节逐位一致(原子写不截断)');
  });

  test('app-polish-3 功能点 2:未写过 → read 返回 null(走网络分支)', () async {
    expect(
      await ThumbDiskStore.I.read('never-written'),
      isNull,
      reason: '磁盘未命中必须回 null,由 ThumbnailImage 走签 URL 下载',
    );
  });

  test('app-polish-3 功能点 2:clear 后 read 返回 null(登出清空语义)', () async {
    await ThumbDiskStore.I.write('a1', _bytes([7, 8, 9]));
    expect(await ThumbDiskStore.I.read('a1'), isNotNull, reason: '前置:已写入');

    await ThumbDiskStore.I.clear();

    expect(
      await ThumbDiskStore.I.read('a1'),
      isNull,
      reason: '登出钩子 clear 后缩略图(含用户素材)必须清空',
    );
    expect(
      await ThumbDiskStore.I.debugSizeBytes(),
      0,
      reason: 'clear 后缓存总字节归零',
    );
  });

  test('app-polish-3 功能点 2:多文件写入后仍能读回最新文件;'
      'debugSizeBytes 与写入总量对账(容量不可注入,LRU 断言降级)', () async {
    final a = _bytes(List.generate(64, (i) => i));
    final b = _bytes(List.generate(128, (i) => 255 - i));
    final c = _bytes([3, 1, 4, 1, 5, 9, 2, 6]);
    await ThumbDiskStore.I.write('old-a', a);
    await ThumbDiskStore.I.write('old-b', b);
    await ThumbDiskStore.I.write('newest-c', c);

    expect(
      await ThumbDiskStore.I.read('newest-c'),
      c,
      reason: '最新写入的文件必须完好可读(超限逐出不误删新文件)',
    );
    expect(await ThumbDiskStore.I.read('old-a'), a, reason: '未超容量不逐出');
    expect(await ThumbDiskStore.I.read('old-b'), b);

    expect(
      await ThumbDiskStore.I.debugSizeBytes(),
      a.length + b.length + c.length,
      reason: 'debugSizeBytes 与落盘字节总量一致',
    );
  });

  test('app-polish-3 功能点 2:IO 异常不抛——目录不存在时 read 回 null、'
      'write/clear 静默无异常(降级路径,widget 环境同语义)', () async {
    final missing = Directory('${dir.path}/nope/never_created');
    ThumbDiskStore.I.debugAttachDirectory(missing);

    expect(
      await ThumbDiskStore.I.read('a1'),
      isNull,
      reason: '目录不可用时 read 必须回 null,不得向 UI 抛异常',
    );
    await ThumbDiskStore.I.write('a1', _bytes([1]));
    await ThumbDiskStore.I.clear();
    expect(
      await ThumbDiskStore.I.debugSizeBytes(),
      0,
      reason: '全部 IO 路径静默降级,总字节按 0 报',
    );

    // 重新挂健康目录后恢复可用(降级不影响后续生命周期)
    ThumbDiskStore.I.debugAttachDirectory(dir);
    await ThumbDiskStore.I.write('a1', _bytes([9]));
    expect(
      await ThumbDiskStore.I.read('a1'),
      _bytes([9]),
      reason: '重挂目录后写入/读取恢复正常',
    );
  });

  test('app-polish-3 功能点 2:文件名清洗——非法字符丢弃,同 id 往返一致;'
      '全非法 id 回退 hashCode 命名仍可往返', () async {
    await ThumbDiskStore.I.write('we/ird:id 资产#1', _bytes([1, 1, 2]));
    expect(
      dir.listSync().whereType<File>().length,
      1,
      reason: '非法字符被清洗,落盘恰好一个文件(不产生路径穿越/乱名)',
    );

    final roundtrip = await ThumbDiskStore.I.read('we/ird:id 资产#1');
    expect(roundtrip, _bytes([1, 1, 2]), reason: '同 id 清洗后命中同一文件');

    await ThumbDiskStore.I.write('资源/夹', _bytes([5, 6]));
    expect(
      await ThumbDiskStore.I.read('资源/夹'),
      _bytes([5, 6]),
      reason: '清洗后为空的 id 回退 hashCode 命名,写入不静默丢失',
    );
    expect(dir.listSync().whereType<File>().length, 2);
  });

  // ── storm-fix W1 #9 增量:代际 / remove / 串行互斥 / _clearing ────────────

  test('storm-fix:write 带 expectedGeneration——同代落盘,跨代丢弃', () async {
    final gen0 = ThumbDiskStore.I.generation;
    await ThumbDiskStore.I.write('g-a', _bytes([1]), expectedGeneration: gen0);
    expect(await ThumbDiskStore.I.read('g-a'), _bytes([1]), reason: '同代写入正常落盘');

    await ThumbDiskStore.I.clear(); // 代数自增
    expect(ThumbDiskStore.I.generation, gen0 + 1);

    await ThumbDiskStore.I.write(
      'g-b',
      _bytes([2]),
      expectedGeneration: gen0,
    ); // 旧代
    expect(
      await ThumbDiskStore.I.read('g-b'),
      isNull,
      reason: '跨代 write 直接丢弃(不产生 tmp/rename)',
    );

    await ThumbDiskStore.I.write(
      'g-c',
      _bytes([3]),
      expectedGeneration: ThumbDiskStore.I.generation,
    );
    expect(await ThumbDiskStore.I.read('g-c'), _bytes([3]), reason: '新代写入不受影响');
  });

  test('storm-fix:remove 带代数——同代可删,旧代迟到 remove 不误删新会话写入', () async {
    final gen0 = ThumbDiskStore.I.generation;
    await ThumbDiskStore.I.write('r-a', _bytes([1]), expectedGeneration: gen0);
    await ThumbDiskStore.I.remove('r-a', expectedGeneration: gen0);
    expect(await ThumbDiskStore.I.read('r-a'), isNull, reason: '同代 remove 生效');

    await ThumbDiskStore.I.write(
      'r-b',
      _bytes([2]),
      expectedGeneration: ThumbDiskStore.I.generation,
    );
    await ThumbDiskStore.I.clear(); // gen+1:新会话
    await ThumbDiskStore.I.write(
      'r-b',
      _bytes([3]),
      expectedGeneration: ThumbDiskStore.I.generation,
    ); // 新会话重写
    await ThumbDiskStore.I.remove('r-b', expectedGeneration: gen0); // 旧代迟到
    expect(
      await ThumbDiskStore.I.read('r-b'),
      _bytes([3]),
      reason: '旧代迟到 remove 被代数挡下,不误删新会话写入',
    );
    await ThumbDiskStore.I.remove(
      'r-b',
      expectedGeneration: ThumbDiskStore.I.generation,
    );
    expect(await ThumbDiskStore.I.read('r-b'), isNull, reason: '新代 remove 生效');
  });

  test('storm-fix:clear 期间 _clearing 使 read 一律回 null;'
      '慢写(写闸)与 clear 串行互斥——clear 前开始的跨代写被丢弃', () async {
    final gen0 = ThumbDiskStore.I.generation;
    await ThumbDiskStore.I.write('c-a', _bytes([1]), expectedGeneration: gen0);
    expect(await ThumbDiskStore.I.read('c-a'), isNotNull, reason: '前置:已写入');

    final gate = Completer<void>();
    ThumbDiskStore.I.debugSetWriteGate(() => gate.future);
    addTearDown(() => ThumbDiskStore.I.debugSetWriteGate(null));

    final w = ThumbDiskStore.I.write(
      'c-b',
      _bytes([2]),
      expectedGeneration: gen0,
    );
    await Future<void>.delayed(Duration.zero); // write body 进入写闸并持有互斥
    final cleared = ThumbDiskStore.I.clear(); // 第一行同步升代 + _clearing

    expect(
      await ThumbDiskStore.I.read('c-a'),
      isNull,
      reason: 'clear 异步删除期间 read 一律 null(防读到旧代文件)',
    );

    gate.complete(); // 放行慢写 → 代数失配被丢弃 → clear 删除随后串行执行
    await w;
    await cleared;

    expect(await ThumbDiskStore.I.read('c-a'), isNull, reason: 'clear 已删除旧文件');
    expect(await ThumbDiskStore.I.read('c-b'), isNull, reason: '跨代写被丢弃');
    expect(await ThumbDiskStore.I.read('c-late'), isNull, reason: '未写即 null');
    await ThumbDiskStore.I.write('c-d', _bytes([9])); // 无代数(兼容旧调用)
    expect(
      await ThumbDiskStore.I.read('c-d'),
      _bytes([9]),
      reason: 'clear 完成后新写入正常(_clearing 复位)',
    );
  });

  test('storm-fix:debugSetReadGate 可空注入与清除(null 恢复直读)', () async {
    final gate = Completer<void>();
    ThumbDiskStore.I.debugSetReadGate(() => gate.future);
    await ThumbDiskStore.I.write(
      'rd-a',
      _bytes([1]),
      expectedGeneration: ThumbDiskStore.I.generation,
    );

    final reading = ThumbDiskStore.I.read('rd-a'); // 挂在慢读闸上
    var done = false;
    unawaited(reading.then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: '读被闸挂起(read 在途窗口可观测)');

    gate.complete();
    await reading;
    expect(done, isTrue);

    ThumbDiskStore.I.debugSetReadGate(null); // 清除:恢复直读
    expect(await ThumbDiskStore.I.read('rd-a'), _bytes([1]));
  });
}
