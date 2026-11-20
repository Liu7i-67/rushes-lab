/**
 * BrandMark — 品牌印记(几何三方块 + material·storage 字标)。
 *
 * LoginPage 与 ForgotPasswordPage 共用同一视觉壳(2026-11-20 方案 §6.1/§6.2:
 * 忘记密码页「照 LoginPage」整段复制过,现抽成单一组件)。JSX 结构 / 内联样式 /
 * 文案与原两页内联版本逐字节一致,渲染结果零变化。
 */
export function BrandMark() {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
      <span style={{ position: 'relative', display: 'inline-block', width: 22, height: 22 }}>
        <span style={{
          position: 'absolute', left: 0, top: 0,
          width: 14, height: 14, background: 'var(--ms-ink)', borderRadius: 2,
        }} />
        <span style={{
          position: 'absolute', left: 4, top: 4,
          width: 14, height: 14, background: 'var(--ms-accent)', borderRadius: 2, opacity: 0.85,
        }} />
        <span style={{
          position: 'absolute', left: 8, top: 8,
          width: 14, height: 14, background: 'var(--ms-emerald)', borderRadius: 2, opacity: 0.7,
        }} />
      </span>
      <span style={{
        fontFamily: 'var(--ms-font-display)', fontWeight: 500, fontSize: 16,
        letterSpacing: '-0.01em', color: 'var(--ms-ink)',
      }}>
        material<span style={{ color: 'var(--ms-accent)' }}>·</span>storage
      </span>
    </div>
  );
}
