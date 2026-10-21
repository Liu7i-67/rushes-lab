/// R2(mobile-ux-polish-2)相册权限补充单测(与 dev 落地的
/// test/services/album_permission_test.dart 分工:该文件钉「请求口径=all」
/// 主断言,本文件补三面):
/// - limited(仅选择部分照片)契约回归:ensurePermission 返回 true(R2 验收
///   「limited 路径正常」的自动化面);
/// - albumPickerConfig 仍 RequestType.all(音频可见可选可传,决策 #1);
/// - Manifest 权限申明六项齐:READ_MEDIA_IMAGES/VIDEO/AUDIO/
///   VISUAL_USER_SELECTED(R2)+ FOREGROUND_SERVICE/FOREGROUND_SERVICE_DATA_SYNC
///   (R4d,targetSdk 36 Android 14+ dataSync 强制 type)。
/// photo_manager 走方法通道 mock(com.fluttercandies/photo_manager),零真机。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/assets/upload_pick.dart';
import 'package:ms_app/services/album.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// photo_manager 插件通道名(photo_manager 3.12 PMConstants.channelPrefix)。
const _pmChannel = MethodChannel('com.fluttercandies/photo_manager');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ensurePermission(R2 补充:limited 契约回归)', () {
    testWidgets('limited(仅选择部分照片)→ true(limited 路径正常)',
        (tester) async {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_pmChannel, (call) async {
        if (call.method == 'requestPermissionExtend') {
          return PermissionState.limited.index;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_pmChannel, null));

      expect(await AlbumService.ensurePermission(), isTrue,
          reason: 'isAuth 含 limited:选择部分照片的用户仍可进选图');
    });
  });

  group('albumPickerConfig(R2 回归锚:选图口径保持 all)', () {
    test('requestType 仍 RequestType.all(音频条目可见可选可传)', () {
      expect(albumPickerConfig().requestType, RequestType.all);
    });
  });

  group('AndroidManifest 权限申明(R2 四项 + R4d 前台服务两项)', () {
    // flutter test 以包根(material-storage/app)为 cwd,主清单按相对路径直读。
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

    test('R2:READ_MEDIA_AUDIO + READ_MEDIA_VISUAL_USER_SELECTED 已申明', () {
      expect(manifest.contains('android.permission.READ_MEDIA_IMAGES'), isTrue,
          reason: '既有项回归');
      expect(manifest.contains('android.permission.READ_MEDIA_VIDEO'), isTrue,
          reason: '既有项回归');
      expect(manifest.contains('android.permission.READ_MEDIA_AUDIO'), isTrue,
          reason: 'R2 新增:缺它 Android 13 含音频请求立即 DENY → 相册选择失败');
      expect(
          manifest.contains(
              'android.permission.READ_MEDIA_VISUAL_USER_SELECTED'),
          isTrue,
          reason: 'R2 新增:Android 14+ limited(部分照片)归并路径');
    });

    test('R4d:FOREGROUND_SERVICE + FOREGROUND_SERVICE_DATA_SYNC 已申明', () {
      expect(manifest.contains('android.permission.FOREGROUND_SERVICE'), isTrue);
      expect(
          manifest.contains(
              'android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
          isTrue,
          reason: 'targetSdk 36(Android 14+)dataSync 型前台服务强制声明');
    });
  });
}
