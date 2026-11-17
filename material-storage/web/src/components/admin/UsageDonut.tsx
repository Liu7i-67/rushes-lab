/**
 * UsageDonut — 使用统计环形占比图(F1 饼图视图,需求 docs/qdev/2026-11-17-usage-stats-pie-and-date-range.md §2 F1.3-F1.4)。
 *
 * - SVG 自绘环形甜甜圈(inline style + CSS vars,同 UsageProportion 视觉语言,不引图表库):
 *   每段一个 <circle>(同半径,stroke-width 即环厚),stroke-dasharray = [弧长, 周长-弧长] +
 *   stroke-dashoffset 按前序弧长累进叠段,rotate(-90°) 从正上方起笔,linecap butt 无圆角缝;
 * - 角度口径:扇区角度 ∝ 行 users / Σ(行 users) 归一化 —— users 跨分组不可加(同一用户
 *   多端重复计数,各行 percent 之和可 >100%),几何上必须归一才能铺满整圆;悬浮 title 与
 *   图例中的百分比仍用行 percent(users / totals.users,与条形视图完全同口径);
 * - users=0 的行不产生扇区(0 角度),图例行保留(与条形视图渲染 0 宽条一致);
 *   Σ users = 0 时整圆不画分段,只画底色空环 + 中心数字;
 * - 每个扇区包原生 SVG <title> 悬浮提示(同日趋势条形 title 惯例),文案「名称 · N 人 · M 次 · X%」;
 * - 布局:环形图 + 图例并排(flex-wrap),容器不够宽(compact 视口)时图例换行到环形图下方;
 * - 不带卡片背景(Section 由调用方包),配色全部来自传入 color(CSS var 字符串,SVG stroke 支持)。
 */
import type { JSX } from 'react';
import { formatUsageLine } from './usage_shared';

export interface UsageDonutSlice {
  key: string;        // 行唯一键(platform_class / platform / network 原值)
  label: string;      // 中文展示名
  users: number;      // 去重用户数
  events: number;     // 事件数
  percent: number;    // 0..100,users/totals.users 口径(展示用,不是角度)
  color: string;      // CSS 颜色,通常是 CSS var 字符串如 'var(--ms-accent)'
}

// 环形几何:viewBox 160×160 居中,环厚 24(半径 64 → 外缘 76,留 4px 呼吸边)
const SIZE = 160;
const CENTER = SIZE / 2;
const RADIUS = 64;
const STROKE_W = 24;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export function UsageDonut({ centerLabel, centerValue, slices }: {
  centerLabel: string;   // 中心短标签,如「去重用户」
  centerValue: number;   // 中心数字,如 totals.users
  slices: UsageDonutSlice[];
}): JSX.Element {
  const sumUsers = slices.reduce((acc, s) => acc + s.users, 0);

  // 扇区弧长 ∝ 行 users / Σ(行 users) 归一化(非 percent 字段);
  // users=0(角度为 0)已过滤,弧长钳到 [0, 周长] 防浮点溢出
  const arcs = slices
    .filter((s) => s.users > 0 && sumUsers > 0)
    .map((s) => ({
      slice: s,
      arc: Math.min(CIRCUMFERENCE, Math.max(0, (s.users / sumUsers) * CIRCUMFERENCE)),
    }));
  // 逐段累进:起点沿圆周顺时针推进,每段 dashoffset = 负的前序弧长之和(段数少,O(n²) 无所谓)
  const segments = arcs.map((seg, i, all) => ({
    ...seg,
    dashoffset: -all.slice(0, i).reduce((acc, a) => acc + a.arc, 0),
  }));

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 20, flexWrap: 'wrap' }}>
      <svg
        viewBox={`0 0 ${SIZE} ${SIZE}`}
        role="img"
        aria-label={`${centerLabel} ${centerValue.toLocaleString()} · 占比环形图`}
        style={{ width: SIZE, maxWidth: 180, height: 'auto', flexShrink: 0 }}
      >
        {/* 底色空环(分段之下的灰轨道;Σ users = 0 时即整图) */}
        <circle
          cx={CENTER}
          cy={CENTER}
          r={RADIUS}
          fill="none"
          stroke="var(--ms-hairline-soft)"
          strokeWidth={STROKE_W}
        />
        {/* 分段:rotate(-90°) 从正上方起笔;中心文字在 g 外不随环旋转 */}
        <g transform={`rotate(-90 ${CENTER} ${CENTER})`}>
          {segments.map(({ slice, arc, dashoffset }) => (
            <circle
              key={slice.key}
              cx={CENTER}
              cy={CENTER}
              r={RADIUS}
              fill="none"
              stroke={slice.color}
              strokeWidth={STROKE_W}
              strokeLinecap="butt"
              strokeDasharray={`${arc} ${CIRCUMFERENCE - arc}`}
              strokeDashoffset={dashoffset}
            >
              <title>
                {`${slice.label} · ${formatUsageLine(slice.users, slice.events, slice.percent)}`}
              </title>
            </circle>
          ))}
        </g>
        {/* 中心两行:数字(var(--ms-ink))+ 短标签(var(--ms-ink-subtle)) */}
        <text
          x={CENTER}
          y={CENTER - 11}
          textAnchor="middle"
          dominantBaseline="central"
          style={{
            fontSize: 22, fontWeight: 600, fill: 'var(--ms-ink)',
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          {centerValue.toLocaleString()}
        </text>
        <text
          x={CENTER}
          y={CENTER + 15}
          textAnchor="middle"
          dominantBaseline="central"
          style={{ fontSize: 11, fill: 'var(--ms-ink-subtle)' }}
        >
          {centerLabel}
        </text>
      </svg>
      {/* 图例:色点 + 名称 + 「N 人 · M 次 · X%」(与条形行 StatRow 同口径文案);
          minWidth + flex-wrap:窄容器整体换行到环形图下方 */}
      <div style={{
        flex: '1 1 180px', minWidth: 180,
        display: 'flex', flexDirection: 'column', gap: 10,
      }}>
        {slices.map((s) => (
          <div key={s.key} style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            <span style={{
              width: 10, height: 10, borderRadius: '50%', background: s.color,
              flexShrink: 0,
            }} />
            <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--ms-ink)' }}>{s.label}</span>
            <span style={{
              marginLeft: 'auto', fontSize: 12, color: 'var(--ms-ink-muted)',
              fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap',
            }}>
              {formatUsageLine(s.users, s.events, s.percent)}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
