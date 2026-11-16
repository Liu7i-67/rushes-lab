/**
 * GroupSearchSelect — 用户组多选(服务端搜索)。
 * §12 增量(2026-11-16 ②):此前三处组多选(组表单目标组 / 建号管理员组 / 编辑用户组)
 * 用 Select showSearch 只在已加载条目里客户端过滤,而 useDirectoryGroups 不传 limit
 * (服务端默认 50 条)→ 组总数超 50 时「运营」等组永远搜不到。本组件:
 *   1) onSearch 防抖 300ms 把关键词喂 useDirectoryGroups(词, 200) 服务端检索
 *      (后端 limit 上限 200;不引新依赖,useRef+setTimeout 自实现);
 *   2) 已选组的 id→名称缓存照 UserPicker briefById 先例:effect 里回填、tagRender
 *      回调里读取 —— 已选但不在当前结果里的 tag 仍显示组名(防换关键词/清空搜索丢文案);
 *   3) 下拉关闭即复位检索词,重开回到全量前 200 条。
 * 用法:受控(Form.Item 注入 value/onChange)或自持 value/onChange 均可;
 * Form.Item name 与提交体不变,纯选项来源升级。
 */
import { Select } from 'antd';
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { useDirectoryGroups } from '../api/hooks';

interface Props {
  value?: string[];
  onChange?: (v: string[]) => void;
  placeholder?: string;
  notFoundContent?: ReactNode;
  disabled?: boolean;
  style?: CSSProperties;
}

export function GroupSearchSelect({
  value, onChange, placeholder = '选择用户组(可多选)',
  notFoundContent = '无用户组', disabled, style,
}: Props) {
  // 防抖后的服务端检索词('' = 全量前 200 条);输入过程只进防抖,不立即发请求
  const [kw, setKw] = useState('');
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const { data: groups, isFetching } = useDirectoryGroups(kw, 200);

  // 已选标签缓存:id → 组名(照 UserPicker briefById 模式:仅 effect 回填、
  // tagRender 回调读取,渲染期主体不读 ref 以过 react-hooks/refs)
  const labelCache = useRef<Map<string, string>>(new Map());
  useEffect(() => {
    for (const g of groups ?? []) labelCache.current.set(g.id, g.name);
  }, [groups]);

  // 卸载时清掉未触发的防抖回调,防 setState 泄漏
  useEffect(() => () => {
    if (timerRef.current) clearTimeout(timerRef.current);
  }, []);

  const onSearch = (q: string) => {
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => setKw(q.trim()), 300);
  };

  // 下拉关闭:立即复位检索词(连带取消未触发的防抖),重开回到全量列表
  const onOpenChange = (open: boolean) => {
    if (!open) {
      if (timerRef.current) clearTimeout(timerRef.current);
      setKw('');
    }
  };

  // 选项 = 当前服务端结果;已选但不在结果里的 id 由 tagRender 从缓存补名称
  const options = useMemo(
    () => (groups ?? []).map(g => ({ value: g.id, label: g.name })),
    [groups],
  );

  return (
    <Select
      mode="multiple"
      showSearch
      optionFilterProp="label"
      allowClear
      value={value}
      onChange={onChange}
      onSearch={onSearch}
      onOpenChange={onOpenChange}
      placeholder={placeholder}
      notFoundContent={notFoundContent}
      disabled={disabled}
      style={style}
      loading={isFetching || !groups}
      options={options}
      tagRender={(props) => {
        const label = labelCache.current.get(props.value as string);
        return (
          <span style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            margin: '2px 4px 2px 0', padding: '1px 8px',
            background: 'var(--ms-hairline-soft)',
            border: '1px solid var(--ms-hairline)',
            borderRadius: 'var(--ms-radius-sm)',
            fontSize: 12, color: 'var(--ms-ink)',
          }}>
            <span>{label ?? (props.value as string)}</span>
            <a onClick={(e) => { e.preventDefault(); props.onClose?.(); }}
               style={{ color: 'var(--ms-ink-muted)', cursor: 'pointer' }}>×</a>
          </span>
        );
      }}
    />
  );
}
