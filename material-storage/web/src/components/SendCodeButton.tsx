/**
 * SendCodeButton — 可复用「获取验证码 / 重新获取(Ns)」倒计时按钮。
 *
 * 手机号绑定与短信找回密码两页共用(2026-11-20 方案 B3):
 * - 倒计时逻辑内聚组件内(useState + useEffect setInterval 每秒递减,
 *   卸载 cleanup;参照 GrantCountdown / MaintenanceBanner 既有范式);
 * - 请求调用与错误文案展示由页面层负责:页面拿到响应 / 错误里的
 *   retry_after 后经 ref 调 start(seconds) 启动倒计时;
 * - 统一规则:**有 retry_after 就以之为初值启动倒计时;无则不启动**
 *   (400 无法发送 / 格式错不带;isv.BUSINESS_LIMIT_CONTROL 的 502 不带;
 *   码作废 429 不带 —— 详见方案 §5.2 retry_after 分型)。
 */
import { Button } from 'antd';
import type { ButtonProps } from 'antd';
import { useEffect, useImperativeHandle, useRef, useState } from 'react';
import type { Ref } from 'react';

/** ref 句柄:页面层在拿到 retry_after 后调 start;reset 强制清零(如换手机号)。*/
export interface SendCodeButtonHandle {
  start: (seconds: number) => void;
  reset: () => void;
}

interface Props extends ButtonProps {
  /** 点击回调(页面层在此发 send-code 请求,按钮只管倒计时展示)。*/
  onClick?: ButtonProps['onClick'];
  /** 附加禁用(如手机号未通过前端预校验);倒计时中恒禁用。*/
  disabled?: boolean;
}

export function SendCodeButton({ onClick, disabled, ref, ...restProps }: Props & { ref?: Ref<SendCodeButtonHandle> }) {
  const [remain, setRemain] = useState(0);
  // start 的实参来源是响应体(页面已持有),不随渲染变化,ref 存最新句柄语义即可
  const remainRef = useRef(0);

  const counting = remain > 0;

  // 每秒递减;counting 翻 false 时 cleanup 并停表
  useEffect(() => {
    if (!counting) return;
    const t = window.setInterval(() => {
      remainRef.current = Math.max(0, remainRef.current - 1);
      setRemain(remainRef.current);
    }, 1000);
    return () => window.clearInterval(t);
  }, [counting]);

  useImperativeHandle(ref, () => ({
    start: (seconds: number) => {
      const s = Math.floor(seconds);
      if (s <= 0) return; // 统一规则:无(≤0)retry_after 不启动倒计时
      remainRef.current = s;
      setRemain(s);
    },
    reset: () => {
      remainRef.current = 0;
      setRemain(0);
    },
  }), []);

  return (
    <Button
      disabled={counting || disabled}
      onClick={onClick}
      {...restProps}
    >
      {counting ? `重新获取(${remain}s)` : '获取验证码'}
    </Button>
  );
}
