/// 边界补测(测试子智能体):版本比较异常面 + AppVersionInfo.fromJson 嵌套 null
/// 与展示口径。纯函数直测,无 IO 无平台依赖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/app_version_info.dart';
import 'package:ms_app/core/update/update_flow.dart';
import 'package:ms_app/core/update/version_compare.dart';

void main() {
  group('版本比较边界补测', () {
    test('远端 0.0.0+0 vs 本地 0.0.0+0 → 不提示(全零也不弹)', () {
      expect(
        isNewerVersion(
          remoteVersion: '0.0.0',
          remoteBuild: 0,
          localVersion: '0.0.0',
          localBuild: 0,
        ),
        isFalse,
      );
    });

    test('远端 0.0.0+1 vs 本地 0.0.0+0 → 提示(version 全零仍按 build 决胜)', () {
      expect(
        isNewerVersion(
          remoteVersion: '0.0.0',
          remoteBuild: 1,
          localVersion: '0.0.0',
          localBuild: 0,
        ),
        isTrue,
      );
    });

    test('远端 4 段 1.2.3.4 vs 本地 1.2.3 → 提示(段数不齐短侧补 0)', () {
      expect(
        isNewerVersion(
          remoteVersion: '1.2.3.4',
          remoteBuild: 0,
          localVersion: '1.2.3',
          localBuild: 99,
        ),
        isTrue,
      );
    });

    test('远端 4 段 1.2.3.4 vs 本地 1.2.4 → 不提示(第 3 段 3<4)', () {
      expect(
        isNewerVersion(
          remoteVersion: '1.2.3.4',
          remoteBuild: 9,
          localVersion: '1.2.4',
          localBuild: 0,
        ),
        isFalse,
      );
    });

    test('本地 version 空串 → 按全零处理,任何非零远端都提示', () {
      expect(
        isNewerVersion(
          remoteVersion: '0.0.1',
          remoteBuild: 0,
          localVersion: '',
          localBuild: 0,
        ),
        isTrue,
      );
      expect(
        isNewerVersion(
          remoteVersion: '0.0.0',
          remoteBuild: 0,
          localVersion: '',
          localBuild: 0,
        ),
        isFalse,
        reason: '全零 vs 全零 → 不提示',
      );
    });

    test('本地 build 字符串解析失败的兜底口径:build=0(PackageInfo.buildNumber', () {
      // 生产路径 _readLocalVersion:int.tryParse('') ?? 0 → 本地 build=0。
      // 这里固化 build=0 时的比较与展示行为,防止兜底口径被无意改动。
      expect(
        isNewerVersion(
          remoteVersion: '1.2.3',
          remoteBuild: 0,
          localVersion: '1.2.3',
          localBuild: 0,
        ),
        isFalse,
        reason: 'version 平局 + build 平局(0 vs 0)→ 不提示',
      );
      expect(
        localVersionLabel((version: '1.2.3', build: 0)),
        '1.2.3+0',
        reason: 'build 兜底 0 的展示口径',
      );
    });

    test('大段号与多段混合不崩(10.20.30 vs 9.99.99.99.99)', () {
      expect(
        compareVersionStrings('10.20.30', '9.99.99.99.99'),
        1,
        reason: '第 1 段 10>9 即决胜',
      );
    });
  });

  group('AppVersionInfo.fromJson 边界补测(嵌套 null 与展示口径)', () {
    Map<String, dynamic> base() => {
      'version': '1.2.3',
      'build': 4,
      'changelog': '',
      'force': false,
      'android': {'url': 'https://resources.taoxiplan.com/huanhuashijie/a.apk'},
    };

    test('android 显式 null(嵌套 null)→ FormatException', () {
      final j = base()..['android'] = null;
      expect(() => AppVersionInfo.fromJson(j), throwsFormatException);
    });

    test('android.url 显式 null → FormatException', () {
      final j = base()..['android'] = {'url': null};
      expect(() => AppVersionInfo.fromJson(j), throwsFormatException);
    });

    test('changelog 纯空白串保留原样(弹窗侧 trim 决定不显示正文)', () {
      final j = base()..['changelog'] = '   ';
      expect(AppVersionInfo.fromJson(j).changelog, '   ');
    });

    test('build 超大 int 不崩', () {
      final j = base()..['build'] = 2147483647;
      expect(AppVersionInfo.fromJson(j).build, 2147483647);
    });
  });
}
