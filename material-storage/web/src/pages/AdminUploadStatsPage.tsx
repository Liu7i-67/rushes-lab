/**
 * /admin/upload-stats — 文件上传数量统计页(2026-11-06 统计面板方案 §5.2)。
 *
 * 按项目分行的生活图文 / 口播视频 / 生活视频 / 其他分类计数 + 全部项目汇总行(置顶首行):
 * - 汇总行不再走表底 Table.Summary,而是合成 UploadStatsRow 注入 dataSource 首位
 *   (用户反馈:Summary 要滚到底才看得到;首行一眼可读,rows 空时也展示全 0);
 * - 筛选行 = 项目多选(数据源 useAllProjects —— useProjects 默认 limit=100 会静默截断,
 *   >100 项目时下拉缺项;两者权限过滤口径相同均走 GET /projects,天然排除归档)
 *   + 日期范围(picker="date" 必填,默认近 30 天)+ 查询按钮;
 * - **手动触发**:查询前 params 恒 null(useUploadStats enabled=false 不发请求),
 *   点「查询」才 setState 传参 —— AdminUsageStatsPage 是参数一变即自动取数、无按钮,
 *   页面形态勿照抄;
 * - 时间只传 `YYYY-MM-DD` 两枚,00:00:00/23:59:59 语义由后端按东八区归一,前端不拼时间;
 * - project_ids 序列化铁律(单参数逗号串)在 useUploadStats hook 内 join(',') 承担;
 * - 已选项目 >200(后端单次上限)查询前 message.warning 拦下,提示「查全部请清空选择」;
 * - 页面守卫:`!(me.is_upload_stats_viewer ?? me.is_system_admin)` → Alert(照
 *   AdminUsageStatsPage 形态);后端 require_upload_stats_viewer 403 兜底同现状双层。
 */
import { Alert, App, Button, DatePicker, Select, Table, Tooltip } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { QuestionCircleOutlined } from '@ant-design/icons';
import { useState } from 'react';
import dayjs, { type Dayjs } from 'dayjs';
import { useAllProjects, useMe, useUploadStats } from '../api/hooks';
import type { UploadStatsParams, UploadStatsRow } from '../api/hooks';
import { errorMessage } from '../api/client';
import { useCompactViewport } from '../lib/use-viewports';

type Range = [Dayjs, Dayjs];

// 单次 project_ids 上限(后端超限 422;§11 查询前轻量 warning,分批查询记遗留)
const PROJECT_IDS_LIMIT = 200;

// 默认窗口:近 30 天([today-29d, today] 自然日;时间归一由后端承担)
const defaultRange = (): Range => [dayjs().subtract(29, 'day'), dayjs()];

const numberFmt = (n: number) => n.toLocaleString();

// ── 汇总行置顶(2026-11-06 用户反馈:表底 Summary 要滚到底才看得到)────────────
// 哨兵 id:汇总行是合成的 UploadStatsRow(非真实项目),id 用不可能与项目 UUID 相撞的常量;
// 各列均无客户端 sorter(排序在后端:total desc → project_name asc),dataSource 顺序即
// 渲染顺序,汇总行恒第一;日后若给列加 sorter,须把该行排除在排序外,否则汇总会被重排。
const SUMMARY_ROW_ID = '__summary_all__';
const isSummaryRow = (r: UploadStatsRow) => r.project_id === SUMMARY_ROW_ID;

// 汇总行视觉区分:轻背景 + 加粗。样式内联在 td(onCell)上 —— antd 的行 hover 底色也是
// 画在 td 上的类样式,优先级打不过内联样式,汇总行 hover 不掉底色;scroll.x 横滚时汇总行
// 与普通行共用同一 colgroup,列宽 / 对齐不受影响。轻背景用既有令牌,深浅色主题各自取值。
const summaryCellProps = (record: UploadStatsRow) =>
  isSummaryRow(record)
    ? { style: { background: 'var(--ms-hairline-soft)', fontWeight: 600 } }
    : {};

/** 分类口径注记(§11 措辞:.ts/.svg 落「其他」是带 mime 前提的条件性结论,勿写成无条件)。*/
function CategoryHint() {
  return (
    <p style={{
      margin: '0 0 16px', fontSize: 12, color: 'var(--ms-ink-subtle)',
      display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'wrap',
    }}>
      <span>
        分类口径:生活图文 = 图片 + livp;口播视频 = 视频且文件名 / 路径含「口播视频」;生活视频 = 其余视频
      </span>
      <Tooltip title={(
        <div style={{ maxWidth: 320 }}>
          <div>· 时间按自然日筛选,后端按东八区(Asia/Shanghai)归一为 00:00:00 ~ 23:59:59;</div>
          <div>· 已删除(软删)资产不计数,恢复后重新计数;归档 / 已删除项目不计;</div>
          <div>· 百度导入资产的「上传时间」= 导入完成时刻(非网盘原始时间);</div>
          <div>· .ts / .svg 等刻意排除的扩展名落「其他」(其 mime 为 video/* / image/* 时仍按 mime 归类);</div>
          <div>· 行内项目编码以当前库为准。</div>
        </div>
      )}>
        <QuestionCircleOutlined style={{ color: 'var(--ms-ink-subtle)' }} />
      </Tooltip>
    </p>
  );
}

export default function AdminUploadStatsPage() {
  const { data: me } = useMe();
  const { message } = App.useApp();
  const compact = useCompactViewport();
  const [range, setRange] = useState<Range>(defaultRange);
  const [projectIds, setProjectIds] = useState<string[]>([]);
  // 手动触发门:查询前 params 恒 null(enabled=false 不发请求),点「查询」才传参
  const [query, setQuery] = useState<UploadStatsParams | null>(null);
  const { data, isFetching, error } = useUploadStats(query);
  // 项目多选数据源:useAllProjects 循环 offset 拉全(勿用 useProjects,>100 静默截断)
  const { data: projects } = useAllProjects();

  const doQuery = () => {
    if (!range[0] || !range[1]) return;
    if (projectIds.length > PROJECT_IDS_LIMIT) {
      message.warning(
        `已选项目 ${projectIds.length} 个,超出单次上限 ${PROJECT_IDS_LIMIT};查全部请清空选择,勿逐个手选`,
      );
      return;
    }
    setQuery({
      projectIds,
      // 只取日期串;00:00:00 / 23:59:59 由后端归一,前端不拼时间(方案 §5.2)
      dateFrom: range[0].format('YYYY-MM-DD'),
      dateTo: range[1].format('YYYY-MM-DD'),
    });
  };

  // 前端体验守卫(后端仍 enforce;me 未就绪时不拦,交给后端 403 → 全局静默兜底)
  if (me && !(me.is_upload_stats_viewer ?? me.is_system_admin)) {
    return (
      <div className="ms-enter" style={{ maxWidth: 520 }}>
        <Alert
          type="warning" showIcon
          message="只有获得授权的用户可以查看文件上传数量统计"
          description="如需查看各项目上传数量统计,请联系系统管理员开通。"
        />
      </div>
    );
  }

  // 汇总行注入 dataSource 首位(rows 恒为数组且后端零填充,空集时汇总展示全 0);
  // 数值口径以后端 summary 为准(= rows 逐列求和),前端不重复求和。
  const tableRows: UploadStatsRow[] = data
    ? [{
        project_id: SUMMARY_ROW_ID,
        project_code: '',
        project_name: '全部项目汇总',
        ...data.summary,
      },
      ...data.rows]
    : [];

  const columns: ColumnsType<UploadStatsRow> = [
    {
      title: '项目', key: 'project', ellipsis: true, onCell: summaryCellProps,
      // 汇总行项目列只留一行加粗文案(合成的 project_code 为空串,不再渲染副行)
      render: (_, r) => isSummaryRow(r) ? (
        <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>全部项目汇总</div>
      ) : (
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 13, color: 'var(--ms-ink)' }}>{r.project_name}</div>
          <div style={{
            fontFamily: 'var(--ms-font-mono)', fontSize: 11, color: 'var(--ms-ink-subtle)',
          }}>{r.project_code}</div>
        </div>
      ),
    },
    { title: '生活图文', dataIndex: 'life_images', align: 'right', width: 100, onCell: summaryCellProps, render: numberFmt },
    { title: '口播视频', dataIndex: 'voice_videos', align: 'right', width: 100, onCell: summaryCellProps, render: numberFmt },
    { title: '生活视频', dataIndex: 'life_videos', align: 'right', width: 100, onCell: summaryCellProps, render: numberFmt },
    { title: '其他', dataIndex: 'others', align: 'right', width: 80, onCell: summaryCellProps, render: numberFmt },
    { title: '合计', dataIndex: 'total', align: 'right', width: 100, onCell: summaryCellProps, render: numberFmt },
  ];

  return (
    <div className="ms-enter">
      {/* 页头(照 AdminAuditPage / AdminUsageStatsPage 惯例) */}
      <div style={{ marginBottom: 'var(--ms-sp-xl)' }}>
        <h1 style={{
          margin: 0,
          fontFamily: 'var(--ms-font-display)',
          fontSize: 32, fontWeight: 500, letterSpacing: '-0.02em',
          color: 'var(--ms-ink)', lineHeight: 1.1,
        }}>文件上传数量统计</h1>
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ms-ink-muted)' }}>
          按项目统计上传数量(不选项目 = 查全部;已删除资产不计数)
        </p>
      </div>

      {/* 筛选行:项目多选 + 日期范围 + 查询(手动触发) */}
      <div style={{
        display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'center',
        marginBottom: 10,
      }}>
        <Select
          mode="multiple"
          value={projectIds}
          onChange={setProjectIds}
          options={(projects ?? []).map(p => ({ value: p.id, label: `${p.name}(${p.code})` }))}
          placeholder={projectIds.length > PROJECT_IDS_LIMIT
            ? '查全部请清空选择,勿逐个手选'
            : '全部项目'}
          allowClear
          maxTagCount={compact ? 1 : 3}
          showSearch
          optionFilterProp="label"
          style={{
            minWidth: compact ? undefined : 260,
            flex: compact ? '1 1 100%' : '1 1 280px',
            maxWidth: 520,
          }}
        />
        <DatePicker.RangePicker
          picker="date"
          value={range}
          onChange={(v) => { if (v && v[0] && v[1]) setRange([v[0], v[1]]); }}
          allowClear={false}
        />
        <Button type="primary" onClick={doQuery} loading={isFetching}
                disabled={!range[0] || !range[1]}>
          查询
        </Button>
      </div>
      <CategoryHint />

      {/* 查询失败(体验层常驻提示;422 的数组型 detail 由 errorMessage 拼成字符串,
          不会触发 React「Objects are not valid as a React child」—— antd v6 铁律;
          非 401/403 错误另有全局 toast,此处不重复 message.error) */}
      {error && (
        <Alert
          type="error" showIcon style={{ marginBottom: 16 }}
          message="查询失败"
          description={errorMessage(error, '查询失败')}
        />
      )}

      {/* 结果表:未发起过查询给引导空态(此时尚无数据,不渲染汇总行);发起查询后汇总行
          恒为首行 —— rows 为空也展示全 0 汇总,数据为零本身就是有效结果。首取数时
          data 未就绪 dataSource 为空,locale 空态文案兜底,与 loading 态不冲突 */}
      {!query ? (
        <Table
          columns={columns}
          dataSource={[]}
          rowKey="project_id"
          scroll={{ x: 'max-content' }}
          locale={{ emptyText: (
            <span style={{ color: 'var(--ms-ink-subtle)' }}>
              选择筛选条件后点击「查询」
            </span>
          ) }}
        />
      ) : (
        <Table
          columns={columns}
          dataSource={tableRows}
          rowKey="project_id"
          loading={isFetching && !data}
          scroll={{ x: 'max-content' }}
          pagination={false}
          locale={{ emptyText: (
            <span style={{ color: 'var(--ms-ink-subtle)' }}>
              所选范围内暂无数据(无可访问的项目或窗口内无上传)
            </span>
          ) }}
        />
      )}
    </div>
  );
}
