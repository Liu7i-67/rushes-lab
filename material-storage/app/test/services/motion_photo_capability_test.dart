/// §7.2 机型能力判定单测:白名单命中/越界、SDK 门槛(31 边界)、channel
/// 异常/null → false 且不缓存(第二次注入成功 → true,证每次重试)、成功
/// 结果记忆化(计数器断言第二次不再调注入函数)、平台 gate 显式前置
/// (注入器零调用 = 不触平台通道,测试环境无 channel)。全程注入假件。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/motion_photo_capability.dart';

AndroidDeviceInfoLike _info(String manufacturer, int sdkInt) =>
    AndroidDeviceInfoLike(
      manufacturer: manufacturer,
      model: 'M',
      sdkInt: sdkInt,
    );

void main() {
  setUp(resetMotionPhotoCapabilityForTest);

  group('isMotionPhotoCapable(纯判定,§5.2 口径)', () {
    test('白名单品牌 + SDK>=31 → true', () {
      expect(isMotionPhotoCapable(_info('Xiaomi', 31)), isTrue);
      expect(isMotionPhotoCapable(_info('google', 31)), isTrue);
      expect(isMotionPhotoCapable(_info('OPPO', 32)), isTrue);
      expect(isMotionPhotoCapable(_info('OnePlus', 33)), isTrue);
      expect(isMotionPhotoCapable(_info('realme', 34)), isTrue);
      expect(isMotionPhotoCapable(_info('vivo', 34)), isTrue);
      // redmi/iqoo 常量集命中(真机 MANUFACTURER 实报 Xiaomi/vivo、这两项
      // 永不命中属预期注记;此处锁常量表成员本身)。
      expect(isMotionPhotoCapable(_info('redmi', 31)), isTrue);
      expect(isMotionPhotoCapable(_info('iqoo', 31)), isTrue);
    });

    test('manufacturer 大小写归一后命中', () {
      expect(isMotionPhotoCapable(_info('XIAOMI', 31)), isTrue);
      expect(isMotionPhotoCapable(_info('Google', 31)), isTrue);
    });

    test('品牌不在白名单 → false(huawei/samsung/honor 初始排除,D1 刻意决策)', () {
      expect(isMotionPhotoCapable(_info('HUAWEI', 34)), isFalse);
      expect(isMotionPhotoCapable(_info('samsung', 34)), isFalse);
      expect(isMotionPhotoCapable(_info('HONOR', 34)), isFalse);
      expect(isMotionPhotoCapable(_info('sony', 33)), isFalse);
      expect(isMotionPhotoCapable(_info('', 31)), isFalse);
    });

    test('SDK=30 的白名单品牌 → false(门槛是 Android 12=31)', () {
      expect(isMotionPhotoCapable(_info('Xiaomi', 30)), isFalse);
      expect(isMotionPhotoCapable(_info('google', 30)), isFalse);
      expect(isMotionPhotoCapable(_info('OPPO', 29)), isFalse);
    });

    test('SDK>=31 的非白名单品牌 → false(两条件缺一不可)', () {
      expect(isMotionPhotoCapable(_info('asus', 31)), isFalse);
      expect(isMotionPhotoCapable(_info('motorola', 34)), isFalse);
    });
  });

  group('motionPhotoCapable(平台 gate 显式前置)', () {
    test('非 Android → false 且注入器零调用(gate 前置于 channel)', () async {
      var calls = 0;
      Future<AndroidDeviceInfoLike?> fetch() async {
        calls += 1;
        return _info('Xiaomi', 31);
      }

      // 测试宿主(VM,非 Android)缺省 gate 即 false:
      expect(await motionPhotoCapable(fetchDeviceInfo: fetch), isFalse);
      // 显式非 Android 同样 false:
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: false,
          fetchDeviceInfo: fetch,
        ),
        isFalse,
      );
      expect(calls, 0, reason: '平台 gate 必须先于 channel,不白付通道调用');
    });
  });

  group('motionPhotoCapable(channel 异常/null → false 且不缓存)', () {
    test('异常 → false;第二次注入成功 → true(证每次重试)', () async {
      var calls = 0;
      Future<AndroidDeviceInfoLike?> throwing() async {
        calls += 1;
        throw StateError('channel 瞬断');
      }

      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: throwing,
        ),
        isFalse,
      );
      // 异常未写记忆化:换成成功注入立即重试并命中
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => _info('Xiaomi', 31),
        ),
        isTrue,
      );
      expect(calls, 1);
    });

    test('PlatformException(真实 channel 异常形态)同走 false 不缓存', () async {
      Future<AndroidDeviceInfoLike?> platformThrows() async {
        throw PlatformException(code: 'unreadable');
      }

      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: platformThrows,
        ),
        isFalse,
      );
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => _info('google', 31),
        ),
        isTrue,
      );
    });

    test('channel 返回 null → false;第二次注入成功 → true(同理重试)', () async {
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => null,
        ),
        isFalse,
      );
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => _info('vivo', 31),
        ),
        isTrue,
      );
    });
  });

  group('motionPhotoCapable(成功结果记忆化)', () {
    test('capable 结果缓存:第二次不再调注入函数(计数器断言)', () async {
      var calls = 0;
      Future<AndroidDeviceInfoLike?> fetch() async {
        calls += 1;
        return _info('Xiaomi', 31);
      }

      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: fetch,
        ),
        isTrue,
      );
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: fetch,
        ),
        isTrue,
      );
      expect(calls, 1, reason: '成功结果记忆化后 channel 只应被调一次');
    });

    test('成功但判 false(非白名单)同样记忆化:不再重试 channel', () async {
      var calls = 0;
      Future<AndroidDeviceInfoLike?> fetch() async {
        calls += 1;
        return _info('samsung', 34);
      }

      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: fetch,
        ),
        isFalse,
      );
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: fetch,
        ),
        isFalse,
      );
      expect(calls, 1, reason: '缓存的是成功结果(机型信息),判定值每次重算');
    });
  });

  group('motionPhotoCapable(生产缺省 channel 路径)', () {
    test('测试环境无通道 → 缺省路径安全 false(MissingPluginException 兜住)', () async {
      // isAndroidPlatform: true 强制走 channel 缺省件;flutter_test 下未注册
      // 通道 → MissingPluginException → false 不外抛。
      expect(await motionPhotoCapable(isAndroidPlatform: true), isFalse);
      // 且异常未缓存:随后注入成功立即生效。
      expect(
        await motionPhotoCapable(
          isAndroidPlatform: true,
          fetchDeviceInfo: () async => _info('Xiaomi', 31),
        ),
        isTrue,
      );
    });
  });
}
