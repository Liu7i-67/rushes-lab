/// B0② Downloads 路返回值映射单测(纯函数 b0DownloadsOutcome):
/// 锁死 2026-10-20 真机实证语义——media_store_plus 0.1.3 saveFile **成功也返回
/// null**,勿以返回值判成败,以无异常为准(null → ok,B4 落盘矩阵同样适用)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:ms_app/features/me/b0_sinks.dart';

void main() {
  group('b0DownloadsOutcome(null 亦成功语义)', () {
    test('null → ok,detail 提示目视核实(真机 0.1.3 成功返 null 钉子)', () {
      final out = b0DownloadsOutcome(null);
      expect(out.isOk, isTrue);
      expect(
          out.detail,
          '已提交 Download/浣花视界/(此版本 saveFile 成功亦返回 null,'
          '未带回文件信息,请目视核实;重名自动加后缀)');
    });

    test('info 非 null → ok,detail=常规路径+saveStatus+uri(原有格式不变)', () {
      final out = b0DownloadsOutcome(SaveInfo(
        name: 'IMG_0001.jpg',
        uri: Uri.parse('content://media/external_primary/downloads/42'),
        saveStatus: SaveStatus.created,
      ));
      expect(out.isOk, isTrue);
      expect(
          out.detail,
          'Download/浣花视界/IMG_0001.jpg(重复名自动加后缀:created)'
          ' uri=content://media/external_primary/downloads/42');
    });

    test('重名 duplicated 状态同样映射成功(重名自动加后缀属正常落盘)', () {
      final out = b0DownloadsOutcome(SaveInfo(
        name: 'IMG_0001 (1).jpg',
        uri: Uri.parse('content://media/external_primary/downloads/43'),
        saveStatus: SaveStatus.duplicated,
      ));
      expect(out.isOk, isTrue);
      expect(out.detail,
          contains('IMG_0001 (1).jpg(重复名自动加后缀:duplicated)'));
    });
  });
}
