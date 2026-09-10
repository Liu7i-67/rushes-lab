import { Grid } from 'antd';

/**
 * 视口判定唯一源。页面禁止自写 Grid.useBreakpoint / innerWidth 判断。
 * <1024（antd lg）切换移动壳层与单栏骨架——iPad 竖屏(768-834)含在内：
 * PC 三栏与 PC 顶栏在该区间物理放不下(见方案 §1.1)。
 * ⚠ antd useBreakpoint 首个 render pass 返回空对象(mobile 分支先渲染)——
 * 硬性约定:消费组件的 hooks 全部置顶调用,mobile/PC 分支只允许切 JSX,
 * 不允许分支内挂不同数量的 hook(桌面端首挂载即崩)。
 */
export function useCompactViewport(): boolean {
  const screens = Grid.useBreakpoint();
  return !screens.lg;
}
