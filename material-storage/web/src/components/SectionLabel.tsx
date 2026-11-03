/**
 * SectionLabel — 详情面板分区标题(弱化 mono 小标)。
 * 自 AssetSummaryPanel 拆出:AI 识别区(AiInfoSection)/ 智能分段区(SegmentSection)
 * 与面板本体共用同一视觉,且避免「面板 → 分区组件 → 面板」循环依赖。
 * 样式与拆出前逐字节一致,面板既有观感零变化。
 */
export function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <div style={{
      fontSize: 10, letterSpacing: '0.08em', textTransform: 'uppercase',
      color: 'var(--ms-ink-subtle)', fontFamily: 'var(--ms-font-mono)',
      fontWeight: 500, marginBottom: 10,
    }}>{children}</div>
  );
}
