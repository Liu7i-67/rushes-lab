export const MAIN_SCROLL_SELECTOR = '[data-ms-main]';
/** compact 下 main 是滚动容器;PC 分支不要用此函数(维持 window.scrollTo) */
export function scrollMainToTop(): void {
  document.querySelector<HTMLElement>(MAIN_SCROLL_SELECTOR)?.scrollTo({ top: 0 });
}
