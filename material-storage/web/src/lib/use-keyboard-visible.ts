/**
 * 移动端软键盘可见性(方案 §3.1 键盘交互)。
 *
 * 触发源:focusin / focusout + visualViewport.resize(聚焦先于键盘弹起,
 * resize 才是键盘真正展开/收起的时刻,双源都重算)。
 * 守卫:仅当 activeElement 为输入类元素(input/textarea/contenteditable)时
 * 才视为键盘 —— 捏合缩放、地址栏收展等非聚焦 resize 一律忽略。
 * 无 visualViewport 的环境(老浏览器/桌面)恒 false,降级为"不隐藏",可接受。
 */
import { useEffect, useState } from 'react';

function isEditable(el: Element | null): boolean {
  if (!el) return false;
  const t = el.tagName;
  return t === 'INPUT' || t === 'TEXTAREA' || (el as HTMLElement).isContentEditable;
}

// 键盘把 visualViewport 压矮超过该阈值才判定"可见",滤掉轻微高度抖动
const KEYBOARD_MIN_SHRINK = 120;

export interface KeyboardState {
  visible: boolean;
  /** 键盘可见时的 visualViewport 高度(px);不可见/不支持时 null */
  viewportHeight: number | null;
}

function useKeyboardState(): KeyboardState {
  const [state, setState] = useState<KeyboardState>({ visible: false, viewportHeight: null });

  useEffect(() => {
    const vv = window.visualViewport;
    const recompute = () => {
      const editing = isEditable(document.activeElement);
      const shrink = vv ? window.innerHeight - vv.height : 0;
      const visible = editing && shrink > KEYBOARD_MIN_SHRINK;
      const viewportHeight = visible && vv ? Math.round(vv.height) : null;
      setState(prev =>
        prev.visible === visible && prev.viewportHeight === viewportHeight
          ? prev
          : { visible, viewportHeight },
      );
    };
    document.addEventListener('focusin', recompute);
    document.addEventListener('focusout', recompute);
    vv?.addEventListener('resize', recompute);
    return () => {
      document.removeEventListener('focusin', recompute);
      document.removeEventListener('focusout', recompute);
      vv?.removeEventListener('resize', recompute);
    };
  }, []);

  return state;
}

/** 键盘是否可见 — 隐藏 TabBar / 批量操作栏用。 */
export function useKeyboardVisible(): boolean {
  return useKeyboardState().visible;
}

/** 键盘期收缩后的视口高度 — 详情 Drawer 收缩(visualViewport.height - 顶栏)用。 */
export function useKeyboardViewportHeight(): number | null {
  return useKeyboardState().viewportHeight;
}
