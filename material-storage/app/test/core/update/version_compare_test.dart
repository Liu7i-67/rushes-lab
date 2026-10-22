/// 测试功能点 T2(F2-3):版本比较纯函数单测 — version 高/低/相等、build 决胜
/// (含远端 build 更低但 version 更高=要更新、version 相同 build 相同=不更新)、
/// 段数不齐(1.0 ≡ 1.0.0)、非数字段按 0、负数段按 0、空串。
/// 纯函数直测,无 IO 无平台依赖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/update/version_compare.dart';

void main() {
  group('parseVersionSegments(切段)', () {
    test('常规三段逐段转 int', () {
      expect(parseVersionSegments('1.2.3'), [1, 2, 3]);
      expect(parseVersionSegments('0.0.0'), [0, 0, 0]);
    });

    test('非数字段按 0(脏数据兜底)', () {
      expect(parseVersionSegments('1.a.2'), [1, 0, 2]);
      expect(parseVersionSegments('x.y'), [0, 0]);
    });

    test('负数段按 0', () {
      expect(parseVersionSegments('1.-2'), [1, 0]);
    });

    test('空串 → [0](split 后单空段落 0,无需特判)', () {
      expect(parseVersionSegments(''), [0]);
    });
  });

  group('compareVersionStrings(逐段比较)', () {
    test('远端高 → 1', () {
      expect(compareVersionStrings('1.2.3', '1.2.2'), 1);
      expect(compareVersionStrings('2.0.0', '1.99.99'), 1);
      expect(compareVersionStrings('1.2.3', '1.2'), 1, reason: '第三段 3 vs 补 0');
    });

    test('远端低 → -1', () {
      expect(compareVersionStrings('1.0.0', '1.0.1'), -1);
      expect(compareVersionStrings('1.9.9', '2.0.0'), -1);
    });

    test('相等 → 0', () {
      expect(compareVersionStrings('1.2.3', '1.2.3'), 0);
    });

    test('段数不齐短侧补 0:1.0 ≡ 1.0.0', () {
      expect(compareVersionStrings('1.0', '1.0.0'), 0);
      expect(compareVersionStrings('1', '1.0.0'), 0);
      expect(compareVersionStrings('1.0', '1.0.1'), -1);
      expect(compareVersionStrings('1.0.1', '1.0'), 1);
    });

    test('非数字段按 0 参与比较', () {
      expect(compareVersionStrings('1.a.2', '1.0.2'), 0);
      expect(compareVersionStrings('1.a', '1.0.1'), -1);
      expect(compareVersionStrings('1.b.1', '1.0'), 1);
    });

    test('空串按 0 处理', () {
      expect(compareVersionStrings('', ''), 0);
      expect(compareVersionStrings('', '0'), 0);
      expect(compareVersionStrings('', '0.0.1'), -1);
      expect(compareVersionStrings('0.0.0', ''), 0);
    });
  });

  group('isNewerVersion(远端 > 本地才提示更新,F2-3 口径)', () {
    test('version 更高 → 要更新(远端 build 更低也弹,version 决胜)', () {
      expect(
        isNewerVersion(
          remoteVersion: '1.1.0',
          remoteBuild: 1,
          localVersion: '1.0.9',
          localBuild: 99,
        ),
        isTrue,
        reason: '远端 build 更低但 version 更高 → 要更新',
      );
    });

    test('version 更低 → 不更新(远端 build 更高也不弹)', () {
      expect(
        isNewerVersion(
          remoteVersion: '0.9.9',
          remoteBuild: 999,
          localVersion: '1.0.0',
          localBuild: 1,
        ),
        isFalse,
      );
    });

    test('version 相同 → build 决胜', () {
      expect(
        isNewerVersion(
          remoteVersion: '1.0.0',
          remoteBuild: 5,
          localVersion: '1.0.0',
          localBuild: 4,
        ),
        isTrue,
      );
      expect(
        isNewerVersion(
          remoteVersion: '1.0.0',
          remoteBuild: 4,
          localVersion: '1.0.0',
          localBuild: 5,
        ),
        isFalse,
        reason: '本地 build 更新(如同版本重发)不提示',
      );
      expect(
        isNewerVersion(
          remoteVersion: '1.0.0',
          remoteBuild: 4,
          localVersion: '1.0.0',
          localBuild: 4,
        ),
        isFalse,
        reason: 'version、build 均相同 → 不更新',
      );
    });

    test('version 相同但段数不齐,仍按相等落 build 决胜', () {
      expect(
        isNewerVersion(
          remoteVersion: '1.0',
          remoteBuild: 6,
          localVersion: '1.0.0',
          localBuild: 5,
        ),
        isTrue,
      );
    });
  });
}
