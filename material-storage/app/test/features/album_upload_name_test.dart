/// iOS 相册上传名解析(T1~T9,2026-10-27 ios-upload-name-ext):
/// extensionFromMime 映射/容错 + resolveAlbumUploadName 扩展名三级优先、
/// 基名兜底、MIME 兜底、平台异常吞掉 + uploadContentTypeFor 优先级。
/// 平台读取全部走注入的 titleOf/mimeOf,不触真实平台通道(PC 上无插件实现)。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/assets/album_upload_name.dart';
import 'package:ms_app/features/assets/upload_sheet.dart'
    show uploadContentTypeFor;
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 模拟 iOS 相册素材:title 为空串(needTitle=false 的现场值);
/// id 含 '/' 用于验证 `IMG_<id>` 兜底名的分隔符净化。
AssetEntity _entity({String title = ''}) => AssetEntity(
  id: 'UUID/L0/001',
  typeInt: 1,
  width: 100,
  height: 100,
  title: title,
);

void main() {
  group('T1 extensionFromMime: MIME ↔ 扩展名映射', () {
    test('iOS 常见 12 个 MIME 全部命中', () {
      const table = <String, String>{
        'image/png': 'png',
        'image/jpeg': 'jpg',
        'image/heic': 'heic',
        'image/heif': 'heif',
        'image/gif': 'gif',
        'image/webp': 'webp',
        'image/tiff': 'tiff',
        'image/bmp': 'bmp',
        'video/quicktime': 'mov',
        'video/mp4': 'mp4',
        'video/x-m4v': 'm4v',
        'video/webm': 'webm',
      };
      expect(table, hasLength(12), reason: '§3.1 映射表固定 12 项');
      table.forEach((mime, ext) {
        expect(extensionFromMime(mime), ext, reason: '$mime 必须映射为 $ext');
      });
    });

    test('入参容错:大写 / 前导点 / 分号参数;未知一律 null', () {
      expect(extensionFromMime('IMAGE/PNG'), 'png', reason: '大小写不敏感');
      expect(extensionFromMime('.png'), 'png', reason: '允许直接给带点扩展名');
      expect(
        extensionFromMime('image/png; charset=utf-8'),
        'png',
        reason: '忽略分号后的参数',
      );
      expect(
        extensionFromMime('application/octet-stream'),
        isNull,
        reason: '未知 MIME 不猜',
      );
      expect(extensionFromMime(''), isNull);
      expect(extensionFromMime(null), isNull);
    });
  });

  group('T2 title 有扩展名(Android 常态)', () {
    test('直接命中,不多发平台调用', () async {
      var titleCalls = 0;
      var mimeCalls = 0;
      final r = await resolveAlbumUploadName(
        _entity(title: 'IMG_1234.PNG'),
        titleOf: (e) async {
          titleCalls += 1;
          return 'IGNORED.PNG';
        },
        mimeOf: (e) async {
          mimeCalls += 1;
          return 'video/mp4';
        },
      );
      expect(r.filename, 'IMG_1234.PNG', reason: 'title 已带扩展名,原样保留且不重复拼 .png');
      expect(r.contentType, 'image/png', reason: '按最终扩展名映射 image/png');
      expect(titleCalls, 0, reason: 'title 非空时不得再发 titleAsync(F8)');
      expect(mimeCalls, 0, reason: '扩展名已命中时不得调用 mimeTypeAsync(F8)');
    });
  });

  group('T3 iOS 空 title + titleAsync 真名', () {
    test('取异步真名及其扩展名', () async {
      var titleCalls = 0;
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        titleOf: (e) async {
          titleCalls += 1;
          return 'IMG_1234.PNG';
        },
      );
      expect(
        r.filename,
        'IMG_1234.PNG',
        reason: 'iOS 空串 title 走 titleAsync 真名',
      );
      expect(r.contentType, 'image/png');
      expect(titleCalls, 1, reason: '空 title 必须且只需取一次 titleAsync');
    });
  });

  group('T4 title 全空 + originFile 路径扩展名', () {
    test('基名兜底 + 路径扩展名,mimeOf 不被调用', () async {
      var mimeCalls = 0;
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        originPath: '/tmp/x/IMG_1234.HEIC',
        titleOf: (e) async => '',
        mimeOf: (e) async {
          mimeCalls += 1;
          return 'image/png';
        },
      );
      // §6 T4 字面值为 'IMG_UUID-L0-001.HEIC',而 §3.1 第 3 步要求扩展名
      // toLowerCase 归一化(落地实现为 .heic);大小写非验收实质,故不敏感断言。
      expect(
        r.filename.toLowerCase(),
        'img_uuid-l0-001.heic',
        reason: '基名走 IMG_<id> 兜底(斜杠净化),扩展名取路径 .HEIC',
      );
      expect(r.contentType, 'image/heic', reason: 'HEIC 按扩展名映射 image/heic');
      expect(mimeCalls, 0, reason: '路径已给出扩展名,mimeTypeAsync 必须惰性不调(F8)');
    });
  });

  group('T5 全空 + MIME 兜底(核心回归)', () {
    test('拼出扩展名并给显式 content_type,不再是裸名 + octet-stream', () async {
      var mimeCalls = 0;
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        titleOf: (e) async => '',
        mimeOf: (e) async {
          mimeCalls += 1;
          return 'image/png';
        },
      );
      expect(
        r.filename,
        'IMG_UUID-L0-001.png',
        reason: 'MIME 兜底必须把扩展名拼进文件名(修复现场裸名坏行)',
      );
      expect(
        r.contentType,
        'image/png',
        reason: '显式 content_type 保证后端缩略图/Web 预览(F3)',
      );
      expect(mimeCalls, 1, reason: 'MIME 只取一次并复用于 contentType,禁止二次调用');
    });
  });

  group('T6 全空且无 MIME', () {
    test('裸基名兜底且 contentType 为 null,不抛错', () async {
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        titleOf: (e) async => '',
        mimeOf: (e) async => null,
      );
      expect(r.filename, 'IMG_UUID-L0-001', reason: '无任何扩展名来源时保留兜底基名');
      expect(r.contentType, isNull, reason: 'null 表示交给调用方按扩展名推断');
    });
  });

  group('T7 平台异常吞掉(F5)', () {
    test('titleOf 抛 PlatformException、mimeOf 抛 Exception:不抛错按兜底', () async {
      final r = await resolveAlbumUploadName(
        _entity(title: ''),
        titleOf: (e) async => throw PlatformException(code: 'asset_deleted'),
        mimeOf: (e) async => throw Exception('iCloud 未下载'),
      );
      expect(r.filename, 'IMG_UUID-L0-001', reason: '读取失败降级为兜底名,不得向上抛');
      expect(r.contentType, isNull, reason: 'MIME 读取失败同样降级为 null');
    });
  });

  group('T8 净化规则不变(F6)', () {
    test("title 含 '/' 时只取 basename", () async {
      final r = await resolveAlbumUploadName(_entity(title: 'a/b.PNG'));
      expect(
        r.filename,
        'b.PNG',
        reason: 'create_upload 拒路径分隔符,文件名只留 basename',
      );
      expect(r.contentType, 'image/png');
    });

    test("点文件 '.PNG' 走基名兜底后按 MIME 补扩展名", () async {
      final r = await resolveAlbumUploadName(
        _entity(title: '.PNG'),
        mimeOf: (e) async => 'image/png',
      );
      expect(
        r.filename,
        'IMG_UUID-L0-001.png',
        reason: '点文件=空基名,兜底名 + MIME 扩展名,不生成 .png 点文件',
      );
      expect(r.contentType, 'image/png');
    });
  });

  group('边界:扩展名幂等', () {
    test('base 已带扩展名时不重复拼接', () async {
      final r = await resolveAlbumUploadName(_entity(title: 'IMG_1234.png'));
      expect(
        r.filename,
        'IMG_1234.png',
        reason: '不得拼成 IMG_1234.png.png(大小写不敏感)',
      );
      expect(r.contentType, 'image/png');
    });
  });

  group('T9 uploadContentTypeFor: content_type 优先级(F7)', () {
    test('.livp 固定 application/zip', () {
      expect(
        uploadContentTypeFor('a.livp'),
        'application/zip',
        reason: '后端按 zip 容器解包 livp,现役语义勿改',
      );
    });

    test('显式 override 优先于 .livp 规则', () {
      expect(
        uploadContentTypeFor('a.livp', override: 'text/plain'),
        'text/plain',
        reason: '显式传入 > .livp 固定 zip',
      );
    });

    test('按扩展名映射(大小写不敏感)', () {
      expect(uploadContentTypeFor('IMG_1234.PNG'), 'image/png');
    });

    test('无扩展名落 application/octet-stream', () {
      expect(
        uploadContentTypeFor('IMG_UUID-L0-001'),
        'application/octet-stream',
        reason: '未知类型维持既有兜底口径',
      );
    });
  });
}
