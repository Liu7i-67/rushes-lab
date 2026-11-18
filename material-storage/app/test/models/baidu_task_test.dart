/// BaiduTask「创建同名文件夹」契约(qdev 2026-11-18 §5 D/§7,web BaiduNewTaskModal
/// 同开关的 App 侧模型口径):
/// - fromJson:`create_same_name_folder` 缺省回落 false(存量响应兼容,同 Me 解析容忍口径);
/// - targetLabel:开关开 ∧ 显式目标夹未删 → 追加 `/末段(source_dir)`(末段 =
///   去尾斜杠后的最后一段,web dirName 同款);夹已删「(已删除)」不加后缀;
/// - auto 承接夹分支不受开关影响(后端 root 模式恒归一 false,模型层亦不进后缀分支)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

/// BaiduTaskOut 形最小 JSON(fromJson 必填仅 id/project_id,其余有缺省兜底)。
Map<String, Object?> taskJson(
  String id, {
  String sourceDir = '/照片',
  String? projectName = '项目一',
  String? targetFolderName = '照片夹',
  bool targetAutoCreated = false,
  Object? createSameNameFolder = _absent,
}) {
  return {
    'id': id,
    'source_dir': sourceDir,
    'project_id': 'p1',
    'project_name': ?projectName,
    'target_folder_id': targetFolderName == null ? null : 'f9',
    'target_folder_name': targetFolderName,
    'target_auto_created': targetAutoCreated,
    'status': 'running',
    'created_at': '2026-11-18T10:00:00Z',
    'updated_at': '2026-11-18T10:01:00Z',
    if (!identical(createSameNameFolder, _absent))
      'create_same_name_folder': createSameNameFolder,
  };
}

/// 哨兵:区分「键缺省」与「显式 null」。
const _absent = Object();

void main() {
  group('BaiduTask.fromJson:create_same_name_folder 缺省口径', () {
    test('字段缺省 → false,targetLabel 不带后缀(存量响应兼容)', () {
      final task = BaiduTask.fromJson(taskJson('t1'));
      expect(task.createSameNameFolder, isFalse);
      expect(task.targetLabel, '项目一 / 照片夹', reason: '开关关=现状行为,逐字节不变');
    });

    test('显式 false → false', () {
      final task = BaiduTask.fromJson(taskJson('t2', createSameNameFolder: false));
      expect(task.createSameNameFolder, isFalse);
      expect(task.targetLabel, '项目一 / 照片夹');
    });

    test('最小 JSON(其余字段缺省)解析不炸且 false', () {
      final task = BaiduTask.fromJson(const {
        'id': 't-min',
        'project_id': 'p1',
        'source_dir': '/照片',
        'status': 'running',
        'created_at': '2026-11-18T10:00:00Z',
        'updated_at': '2026-11-18T10:01:00Z',
      });
      expect(task.createSameNameFolder, isFalse);
      expect(task.targetLabel, 'p1 / (已删除)', reason: 'project_name/target_folder_name 双缺 → 项目 id + 已删除兜底');
    });
  });

  group('BaiduTask.targetLabel:开关开 ∧ 显式夹未删 → 追加 /末段', () {
    test('true + 显式夹 → 追加末段(常规单段路径)', () {
      final task = BaiduTask.fromJson(
        taskJson('t3', sourceDir: '/照片', createSameNameFolder: true),
      );
      expect(task.createSameNameFolder, isTrue);
      expect(task.targetLabel, '项目一 / 照片夹/照片');
    });

    test('末段派生:多段路径取最后一段', () {
      final task = BaiduTask.fromJson(
        taskJson('t4', sourceDir: '/旅行/2026/婚礼精修', createSameNameFolder: true),
      );
      expect(task.targetLabel, '项目一 / 照片夹/婚礼精修');
    });

    test('末段派生:尾斜杠归一(单尾/多尾均取去尾后末段)', () {
      final single = BaiduTask.fromJson(
        taskJson('t5', sourceDir: '/旅行/婚礼精修/', createSameNameFolder: true),
      );
      expect(single.targetLabel, '项目一 / 照片夹/婚礼精修');

      final multi = BaiduTask.fromJson(
        taskJson('t6', sourceDir: '/婚礼精修///', createSameNameFolder: true),
      );
      expect(multi.targetLabel, '项目一 / 照片夹/婚礼精修');
    });

    test('project_name 缺省回退 projectId,后缀拼接不受影响', () {
      final task = BaiduTask.fromJson(
        taskJson('t7', projectName: null, sourceDir: '/照片', createSameNameFolder: true),
      );
      expect(task.targetLabel, 'p1 / 照片夹/照片');
    });
  });

  group('BaiduTask.targetLabel:不加后缀的分支', () {
    test('夹已删(target_folder_name=null)→「(已删除)」不加后缀', () {
      final task = BaiduTask.fromJson(
        taskJson('t8', targetFolderName: null, createSameNameFolder: true),
      );
      expect(task.createSameNameFolder, isTrue, reason: '布尔照收;后缀只由「夹未删」闸门');
      expect(task.targetLabel, '项目一 / (已删除)');
    });

    test('auto 承接夹分支不受开关影响(true 防御态也不进后缀)', () {
      final task = BaiduTask.fromJson(
        taskJson(
          't9',
          targetFolderName: null,
          targetAutoCreated: true,
          createSameNameFolder: true,
        ),
      );
      expect(task.targetLabel, '项目一 / 项目根(自动创建承接夹)',
          reason: '后端 root 模式恒归一 false(F4);模型层即使收到 true 也不加后缀');
    });

    test('auto + 缺省 false = 现状基线', () {
      final task = BaiduTask.fromJson(
        taskJson('t10', targetFolderName: null, targetAutoCreated: true),
      );
      expect(task.createSameNameFolder, isFalse);
      expect(task.targetLabel, '项目一 / 项目根(自动创建承接夹)');
    });
  });
}
