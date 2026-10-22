/// 测试功能点 T3(F2-2):AppVersionInfo.fromJson 防御式解析 —
/// 完整解析 / build 缺失=0 / changelog 缺失='' / force 缺失=false /
/// 各字段类型异常按默认值兜底;version 空(缺失/空串/类型错)与
/// android 缺失或 url 空 → FormatException(「无有效更新信息」)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/app_version_info.dart';

void main() {
  /// 完整契约 JSON(F1-5 契约结构;jsonDecode 产物即 Map<String, dynamic>)。
  Map<String, dynamic> fullJson() => {
        'version': '1.2.3',
        'build': 7,
        'changelog': '修复若干问题',
        'force': true,
        'android': {
          'url':
              'https://resources.taoxiplan.com/huanhuashijie/huanhuashijie-1.2.3.apk',
        },
      };

  group('完整与缺省字段(F2-2 默认值口径)', () {
    test('完整 JSON 全字段解析', () {
      final info = AppVersionInfo.fromJson(fullJson());
      expect(info.version, '1.2.3');
      expect(info.build, 7);
      expect(info.changelog, '修复若干问题');
      expect(info.force, isTrue);
      expect(
          info.androidUrl,
          'https://resources.taoxiplan.com/huanhuashijie/huanhuashijie-1.2.3.apk');
    });

    test('最小 JSON:仅 version + android.url,其余落默认值', () {
      final info = AppVersionInfo.fromJson({
        'version': '2.0.0',
        'android': {'url': 'https://cdn/huanhuashijie-2.0.0.apk'},
      });
      expect(info.version, '2.0.0');
      expect(info.build, 0, reason: 'build 缺失 = 0');
      expect(info.changelog, '', reason: 'changelog 缺失 = 空串');
      expect(info.force, isFalse, reason: 'force 缺失 = false(D5 仅透传)');
    });

    test('build/changelog/force 显式 null 同缺失', () {
      final info = AppVersionInfo.fromJson({
        'version': '2.0.0',
        'build': null,
        'changelog': null,
        'force': null,
        'android': {'url': 'https://cdn/a.apk'},
      });
      expect(info.build, 0);
      expect(info.changelog, '');
      expect(info.force, isFalse);
    });
  });

  group('类型异常按默认值兜底(防御式,不抛)', () {
    test("build 非 int('7' / 7.0 / true)→ 0", () {
      final asString = fullJson()..['build'] = '7';
      expect(AppVersionInfo.fromJson(asString).build, 0);
      final asDouble = fullJson()..['build'] = 7.0;
      expect(AppVersionInfo.fromJson(asDouble).build, 0);
      final asBool = fullJson()..['build'] = true;
      expect(AppVersionInfo.fromJson(asBool).build, 0);
    });

    test("changelog 非 String(123 / List)→ ''", () {
      final asInt = fullJson()..['changelog'] = 123;
      expect(AppVersionInfo.fromJson(asInt).changelog, '');
      final asList = fullJson()..['changelog'] = ['a'];
      expect(AppVersionInfo.fromJson(asList).changelog, '');
    });

    test("force 非 bool('true' / 1)→ false", () {
      final asString = fullJson()..['force'] = 'true';
      expect(AppVersionInfo.fromJson(asString).force, isFalse);
      final asInt = fullJson()..['force'] = 1;
      expect(AppVersionInfo.fromJson(asInt).force, isFalse);
    });
  });

  group('无有效更新信息 → FormatException(F2-2:version / android.url 校验)', () {
    test('version 缺失 / 空串 / 非字符串', () {
      final missing = fullJson()..remove('version');
      expect(() => AppVersionInfo.fromJson(missing), throwsFormatException);
      final empty = fullJson()..['version'] = '';
      expect(() => AppVersionInfo.fromJson(empty), throwsFormatException);
      final wrongType = fullJson()..['version'] = 123;
      expect(() => AppVersionInfo.fromJson(wrongType), throwsFormatException);
    });

    test('android 缺失 / 非 Map', () {
      final missing = fullJson()..remove('android');
      expect(() => AppVersionInfo.fromJson(missing), throwsFormatException);
      final notMap = fullJson()..['android'] = 'https://cdn/a.apk';
      expect(() => AppVersionInfo.fromJson(notMap), throwsFormatException);
    });

    test('android.url 缺失 / 空串 / 非字符串', () {
      final missing = fullJson();
      (missing['android'] as Map).remove('url');
      expect(() => AppVersionInfo.fromJson(missing), throwsFormatException);
      final empty = fullJson()
        ..['android'] = {'url': ''};
      expect(() => AppVersionInfo.fromJson(empty), throwsFormatException);
      final wrongType = fullJson()
        ..['android'] = {'url': 5};
      expect(() => AppVersionInfo.fromJson(wrongType), throwsFormatException);
    });
  });
}
