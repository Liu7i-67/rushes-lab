/**
 * FolderViewModeSwitch — PC 文件夹三视图切换器(详情/小图/大图)antd Segmented 封装。
 * 方案出处:docs/qdev/2026-11-25-pc-folder-view-modes.md §2.2;
 * 测试后修复轮 P1-2:VIEW_MODE_OPTIONS(含 3 个 icon import)此前在 FolderDetailPage
 * 与 ProjectDetailPage 逐字重复,收敛于此防漂移。
 * 职责边界:只定义档位(TableOutlined 详情 / AppstoreOutlined 小图 / PicRightOutlined 大图)
 * 并渲染 Segmented;onChange 内部完成 FolderViewMode 类型收窄,页面层不再 cast;
 * 模式持久化在 hooks/use-view-mode.ts(本文件不感知 localStorage 与视口)。
 */
import { Segmented } from 'antd';
import { AppstoreOutlined, PicRightOutlined, TableOutlined } from '@ant-design/icons';
import type { FolderViewMode } from '../hooks/use-view-mode';

// PC 三视图 Segmented 档位(图标+文字,icon 惯例跟 @ant-design/icons;方案 §2.2)
const VIEW_MODE_OPTIONS: { value: FolderViewMode; label: React.ReactNode }[] = [
  { value: 'detail', label: <><TableOutlined /> 详情</> },
  { value: 'small', label: <><AppstoreOutlined /> 小图</> },
  { value: 'large', label: <><PicRightOutlined /> 大图</> },
];

interface Props {
  value: FolderViewMode;
  onChange: (m: FolderViewMode) => void;
}

export function FolderViewModeSwitch({ value, onChange }: Props) {
  return (
    <Segmented
      value={value}
      onChange={(v) => onChange(v as FolderViewMode)}
      options={VIEW_MODE_OPTIONS}
    />
  );
}
