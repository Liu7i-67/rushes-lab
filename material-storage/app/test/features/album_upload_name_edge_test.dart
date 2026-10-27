/// iOS 相册上传名解析的补充边界/异常用例(2026-10-27 ios-upload-name-ext,
/// 测试子智能体独立视角):title 与路径扩展名冲突、视频族、svg 排除、
/// originPath 四种空/畸形分支、纯空白 title、id 含反斜杠、空白 override、
/// 幂等复算。平台读取全部走注入 titleOf/mimeOf,不触真实平台通道。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/content_types.dart' show contentTypeForFilename;
import 'package:ms_app/features/assets/album_upload_name.dart';
import 'package:ms_app/features/assets/upload_sheet.dart'
    show uploadContentTypeFor;
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 模拟 iOS 相册素材:title 为空串(needTitle=false 的现场值);
/// id 形如 PHAsset localIdentifier(`UUID/L0/001`)。
AssetEntity _entity({String title = '', String id = 'UUID/L0/001'}) =>
    AssetEntity(id: id, typeInt: 1, width: 100, height: 100, title: title);

void main() {
  test('B1 title 扩展名压过 originPath 扩展名(title 优先,零平台调用)', () async {
    var titleCalls = 0;
    var mimeCalls = 0;
    final r = await resolveAlbumUploadName(
      _entity(title: 'IMG_1234.PNG'),
      originPath: '/tmp/x/IMG_1234.HEIC',
      titleOf: (e) async {
        titleCalls += 1;
        return 'IGNORED.HEIC';
      },
      mimeOf: (e) async {
        mimeCalls += 1;
        return 'image/heic';
      },
    );
    expect(r.filename, 'IMG_1234.PNG', reason: 'title 有值且带扩展名,不得被路径 .HEIC 覆盖');
    expect(r.contentType, 'image/png', reason: 'content_type 跟随最终文件名 .PNG');
    expect(titleCalls, 0, reason: 'title 非空不得再发 titleAsync(F8)');
    expect(mimeCalls, 0, reason: '扩展名已命中不得调用 mimeTypeAsync(F8)');
  });

  test('B2 全空 + video/quicktime → .mov + video/quicktime(视频族同链路)', () async {
    var mimeCalls = 0;
    final r = await resolveAlbumUploadName(
      _entity(title: ''),
      titleOf: (e) async => '',
      mimeOf: (e) async {
        mimeCalls += 1;
        return 'video/quicktime';
      },
    );
    expect(r.filename, 'IMG_UUID-L0-001.mov', reason: '视频 MIME 必须补 .mov 扩展名');
    expect(r.contentType, 'video/quicktime');
    expect(mimeCalls, 1, reason: 'MIME 只取一次并复用于 contentType');
  });

  test(
    'B3 mimeOf=image/svg+xml → contentType 必须为 null(契约 §3.1 第 5 步)',
    () async {
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        titleOf: (e) async => '',
        mimeOf: (e) async => 'image/svg+xml',
      );
      expect(r.contentType, isNull, reason: 'svg 被显式排除,不得作为 image/* 显式值');
      expect(r.filename, 'IMG_UUID-L0-001', reason: 'svg 不在 MIME→扩展名表,扩展名仍未知');
    },
  );

  test('B4 originPath null/空串/无扩展名/仅扩展名 四分支均不抛错', () async {
    final paths = <String?>[null, '', '/tmp/IMG_1234', '/tmp/.png'];
    for (final p in paths) {
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        originPath: p,
        titleOf: (e) async => '',
        mimeOf: (e) async => null,
      );
      expect(
        r.filename,
        'IMG_UUID-L0-001',
        reason: 'originPath=$p 无可用扩展名时必须走兜底名且不抛错',
      );
      expect(
        r.contentType,
        isNull,
        reason: 'originPath=$p 且无 MIME 时 contentType=null',
      );
    }
  });

  test('B5 title 全空白视同空,走 titleAsync 真名', () async {
    var titleCalls = 0;
    final r = await resolveAlbumUploadName(
      _entity(title: '   '),
      titleOf: (e) async {
        titleCalls += 1;
        return 'IMG_1234.PNG';
      },
    );
    expect(r.filename, 'IMG_1234.PNG', reason: '纯空白 title 视同空串');
    expect(r.contentType, 'image/png');
    expect(titleCalls, 1, reason: '空白 title 必须且只需取一次 titleAsync');
  });

  test(r'B6 e.id 含反斜杠 → 兜底名不得带 / 或 \ (create_upload 400)', () async {
    final r = await resolveAlbumUploadName(
      _entity(title: '', id: r'UUID\L0\001'),
      titleOf: (e) async => '',
      mimeOf: (e) async => null,
    );
    expect(r.filename, 'IMG_UUID-L0-001', reason: '反斜杠必须净化成 -');
    for (final bad in ['/', r'\']) {
      expect(r.filename.contains(bad), isFalse, reason: '兜底名不得含路径分隔符 $bad');
    }
  });

  test('B7 空白 override 不得当显式值(落扩展名/octet-stream 推断)', () {
    expect(
      uploadContentTypeFor('', override: '  '),
      'application/octet-stream',
      reason: '空白 override 视同未传',
    );
    expect(
      uploadContentTypeFor('a.livp', override: '   '),
      'application/zip',
      reason: '空白 override 不得覆盖 .livp 固定 zip',
    );
  });

  test('B8 同一 AssetEntity 连续两次解析:结果一致且不泄漏状态', () async {
    var titleCalls = 0;
    var mimeCalls = 0;
    final e = _entity(title: '');
    var titleReply = 'IMG_0001';
    var mimeReply = 'image/heic';
    Future<AlbumUploadName> run() => resolveAlbumUploadName(
      e,
      titleOf: (x) async {
        titleCalls += 1;
        return titleReply;
      },
      mimeOf: (x) async {
        mimeCalls += 1;
        return mimeReply;
      },
    );

    final first = await run();
    final second = await run();
    expect(first, second, reason: '同一输入连续两次必须给出一致结果');
    expect(first.filename, 'IMG_0001.heic');
    expect(first.contentType, 'image/heic');
    expect((titleCalls, mimeCalls), (2, 2), reason: '每次调用各取一次,不得跨调用缓存泄漏');

    // 第三次换 reader 输出:结果必须跟随新输入,证明无模块级/实例级隐藏状态
    titleReply = 'IMG_0002.PNG';
    final third = await run();
    expect(third.filename, 'IMG_0002.PNG');
    expect(third.contentType, 'image/png');
    expect((titleCalls, mimeCalls), (3, 2), reason: 'title 带扩展名时不得再调 mimeOf');
  });

  test('B9 新增 tif/tiff → image/tiff 映射回归(本次 content_types 改动)', () {
    expect(contentTypeForFilename('scan.tif'), 'image/tiff');
    expect(contentTypeForFilename('scan.TIFF'), 'image/tiff', reason: '大小写不敏感');
    expect(uploadContentTypeFor('scan.tiff'), 'image/tiff');
    expect(
      uploadContentTypeFor('scan.tif', override: ''),
      'image/tiff',
      reason: '空 override 回落到扩展名推断',
    );
  });
}
