/// 测试功能点 4(B2):文件夹树组树 — parent_folder_id 多级嵌套、孤儿/环不可达
/// 不渲染(PM 决策:对标 web buildTree 自 null 根递归,2026-10-20 B2 修复改口径)、
/// 根序保持。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/folders/folder_tree.dart';
import 'package:ms_app/models/models.dart';

Folder f(String id, {String? parent, int count = 0}) => Folder(
  id: id,
  name: '夹$id',
  parentFolderId: parent,
  subtreeFileCount: count,
);

void main() {
  test('多级嵌套:一级→二级→三级 逐层挂 children', () {
    final roots = buildFolderTree([
      f('r'),
      f('m', parent: 'r'),
      f('l', parent: 'm'),
    ]);
    expect(roots, hasLength(1));
    expect(roots.first.folder.id, 'r');
    expect(roots.first.children.single.folder.id, 'm');
    expect(roots.first.children.single.children.single.folder.id, 'l');
  });

  test('多棵树 + 根序保持后端返回序(minio_prefix 序)', () {
    final roots = buildFolderTree([f('b'), f('a'), f('b1', parent: 'b')]);
    expect(roots.map((n) => n.folder.id).toList(), ['b', 'a']);
    expect(roots.first.children.single.folder.id, 'b1');
  });

  test('孤儿不渲染(PM 决策对标 web):parent 指向不存在的夹 → 整支不可见', () {
    final roots = buildFolderTree([
      f('orphan', parent: 'ghost'), // 父夹不在列表
      f('child', parent: 'orphan'), // 挂在孤儿下:同样不可达 → 一并不渲染
    ]);
    expect(roots, isEmpty);
  });

  test('孤儿不渲染不殃及正常根:同一列表里的一级夹照常出现', () {
    final roots = buildFolderTree([f('ok'), f('orphan', parent: 'ghost')]);
    expect(roots.map((n) => n.folder.id).toList(), ['ok']);
  });

  test('环不可达不渲染:A↔B 互相挂 → 从 null 根走不到,双双隐藏且不死循环', () {
    final roots = buildFolderTree([f('a', parent: 'b'), f('b', parent: 'a')]);
    expect(roots, isEmpty);
  });

  test('自指不渲染:a→a', () {
    final roots = buildFolderTree([f('a', parent: 'a')]);
    expect(roots, isEmpty);
  });

  test('环外节点挂在环成员下:随环不可达一并隐藏', () {
    // x→a→b→a:x 的父 a 存在但 a 自身不可达 → x 同语义隐藏
    final roots = buildFolderTree([
      f('x', parent: 'a'),
      f('a', parent: 'b'),
      f('b', parent: 'a'),
    ]);
    expect(roots, isEmpty);
  });

  test(
    'Folder.from 契约:subtree_file_count / direct_file_count / is_sensitive 解析',
    () {
      final j = {
        'id': 'f1',
        'project_id': 'p1',
        'parent_folder_id': null,
        'name': '根夹',
        'minio_prefix': '根夹/',
        'is_sensitive': true,
        'created_at': '2026-10-20T00:00:00Z',
        'subtree_file_count': 7,
        'direct_file_count': 3,
        // 列表响应里 my_can_* 恒 False — 模型照收,但只有详情值可信(字段级注释)
        'my_can_download': false,
      };
      final folder = Folder.fromJson(j);
      expect(folder.subtreeFileCount, 7);
      expect(folder.directFileCount, 3);
      expect(folder.isSensitive, isTrue);
      expect(folder.parentFolderId, isNull);
      expect(folder.myCanDownload, isFalse);
    },
  );

  test('Folder.from 旧后端兼容:direct_file_count 缺键默认 0(K1)', () {
    final j = {
      'id': 'f2',
      'project_id': 'p1',
      'parent_folder_id': null,
      'name': '旧响应夹',
      'minio_prefix': '旧响应夹/',
      'is_sensitive': false,
      'created_at': '2026-10-20T00:00:00Z',
      'subtree_file_count': 5,
    };
    final folder = Folder.fromJson(j);
    expect(folder.directFileCount, 0);
    expect(folder.subtreeFileCount, 5);
  });
}
