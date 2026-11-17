---
name: hh2-outage
description: 内网素材服务器(192.168.110.221)断电/失联/挂死/挂起事故处理手册:一分钟判别→定位决策树→处置→恢复验证,含 2026-11-17 断电事故完整档案(GNOME 空闲挂起根因)、softdog 看门狗(300s)与跳板机企微告警 cron 部署细节。凡遇服务器打不开、公网入口 502、反向隧道断、ping 不通 110.221、公司断电/来电后要确认服务器状态等场景时使用——即使用户没说"事故"这个词。
---

# 内网服务器断电/失联事故处理手册

## 0. 全链路架构(一切判别的地基)

```
公网用户 ──→ 阿里云跳板机 aliyun-swas(47.108.196.211,不受公司断电影响)
              nginx :8080/:18080/:443 → 127.0.0.1:8081(dev)/18081(prod)
                        ↑ 反向 SSH 隧道(账号 tunnel,msdev 的 ssh -N -R,10s 重试循环)
内网用户 ──→ 内网服务器 192.168.110.221(:8090 dev / :80 prod,容器栈 ×24)
```

- **内网服务器唯一入站通道 = 反向隧道**(机器在 NAT 后,无公网、无 VPN)——隧道死 = 远程彻底无门。
- **服务器是一台带 GUI 的工作站型服务器**:default target=`graphical`,gdm3 + GNOME + RTX 3080 Ti,白天有人当桌面用。⚠ **任何"空闲即挂起/关机"类策略都可能在无人值守时段把它变假死**(2026-11-17 事故根因,已 mask,见 §5/§6.5)。
- 时区:内网服务器日志是 **UTC**,跳板机/本机是北京时间,对照时间线一律 +8。
- SSH 别名:`file_service`(msdev 直连,**无 sudo**)/`hh2-prod`(huanhua 免密 sudo,走隧道)——见 `~/.ssh/config`。

## 1. 一分钟判别(先跑这三条,别猜)

```bash
# ① 公网入口(本机直接跑):502 = 跳板机活着但隧道死;超时 = 跳板机/网络问题
curl -s -o /dev/null -m 8 -w "%{http_code}\n" http://47.108.196.211:8080/api/v1/auth/me   # 期望 401
# ② 隧道端口(跳板机侧):三口全无监听 = 隧道不在
ssh aliyun-swas 'ss -tln | grep -E ":(12222|8081|18081)\b"'
# ③ 隧道守护重连记录:断链时 ~10s 一次刷屏;**零记录 = 整机没电/挂死/睡着**(最强证据)
ssh aliyun-swas 'journalctl -u sshd --since "<事发日>" --no-pager | grep "for tunnel" | tail -20'
# ③b 服务器侧定性(可达时):挂起还是挂死,一条命令见分晓(必须 sudo,见 §7)
ssh hh2-prod 'sudo journalctl -b 0 -k --no-pager | grep -E "PM: suspend"'
```

## 2. 定位决策树

| 证据组合 | 结论 | 依据 |
| --- | --- | --- |
| ②三口全无 + ③零重连记录 | **整机没电 / 挂死 / 挂起假死**(电源灯亮≠系统活着) | 守护正常时必在 10s 重试;睡着/挂死时出站全停 |
| 服务器可达 → ③b 有 `PM: suspend entry` 无 `exit` | **挂起假死**(按一下电源键/键盘通常能唤醒,但空闲超时未解除会再睡,唤醒后立刻做 §6.5 的 mask) | s2idle 入睡后无唤醒源 |
| ②缺端口 + ③有重连刷屏 | 服务器活着,隧道进程/网络单独出问题 | 重试说明 OS 在跑 |
| ①502 但 ②正常 | 跳板机 nginx 与隧道之间的问题 | 少见,查跳板机 nginx |
| 公网通、仅内网不通 | 本机网段/网卡选择问题(见下方"双网卡"事实) | — |

**本机双网卡事实(2026-11-17 实测)**:运维机**常态下有线+WiFi 同时连接**——有线在 192.168.1.x 网段(**到不了服务器**),WiFi 拿 192.168.110.x(与服务器同段)。**直连内网服务器只能走 WiFi**,无需断开有线,显式绑定源地址已实测可通:`ping -S 192.168.110.14 192.168.110.221`。若 WiFi 拿到的地址不同,`ipconfig` 现查再绑。

**内网侧二层定位**(本机需在 110.x 网段):
`Reply from <本机IP>: Destination host unreachable` = **本机 ARP 解析失败,改网关/加路由无效,别动网络配置**。
全网段扫一遍(`seq 1 254 | xargs -P 64 -I@ ping -n 1 -w 400 192.168.110.@ >/dev/null 2>&1; arp -a | grep 192.168.110`):
百台主机有 MAC、唯独 .221 无条目 → 锁定服务器自身(挂死与挂起在此完全同貌,区分靠 ③b)。

## 3. 处置

1. **先定性再动手**(§1 ③b):挂起假死 → 到机器跟前按一下电源键/动键盘即可唤醒(2026-11-17 实证:按键唤醒成功);唤醒后**立即确认睡眠抑制在位**(§6.5),否则空闲已超时会秒睡回去。
2. **真挂死(灯亮风扇转、ARP 死、无 suspend 记录)= 远程无解,现场硬重启**(长按电源 5s 再开机)。历史实证:重启后约 4 分钟全套自愈(BIOS 通电自启+隧道守护+容器 restart 策略都可靠)。
3. **softdog 看门狗(300s,§6)兜真挂死**:冻结 300 秒自动硬复位。⚠ 防不住挂起(s2idle 连定时器一起冻结)——治本靠 §6.5 的睡眠 mask。看门狗触发后用 `last -x | head` 确认意外重启、`sudo journalctl -b -1 -e` 找冻结前线索。
4. 跳板机告警 cron(§6.6)会在失联 ≥5 分钟时推企微群,恢复自动通知——失联后不必人肉盯。
5. 重启后仍无 ARP → 查中间交换机(断电后半死,断电重启它)/网线/换口。

## 4. 恢复验证清单(五项全过才算恢复)

```bash
ping -n 2 192.168.110.221                                                    # ① 通
ssh -o ConnectTimeout=5 file_service 'docker ps --format "{{.Names}}\t{{.Status}}"'   # ② 24 容器全 Up
ssh aliyun-swas 'ss -tln | grep -cE ":(12222|8081|18081)\b"'                 # ③ =3(或 4,IPv6 重复计)
curl -s -o /dev/null -m 8 -w "%{http_code}" http://47.108.196.211:8080/api/v1/auth/me   # ④ 401
curl -s -o /dev/null -m 8 -w "%{http_code}" http://47.108.196.211:18080/ms-static/web/  # ⑤ 200
```

容器名单(2026-11-17 快照):ms-api/ms-worker/ms-db/ms-mcp/ms-redis + 同名 `-dev` + poc-nginx(±-dev)/poc-openfga(±-dev)/poc-openfga-db(±-dev)/poc-minio-thumbs(±-dev)/poc-pigsty-minio(±-dev)/poc-presigner(±-dev)/poc-console(±-dev)。`poc-openfga-migrate(±-dev)` Exited(0) 是一次性任务,**正常勿动**。

## 5. 2026-11-17 事故档案(北京时间;根因 10:30 定案)

**根因:GNOME 桌面空闲自动挂起(s2idle)且醒不来。** 服务器 default target=graphical,GNOME(greeter)空闲 1200 秒即自动挂起;`/sys/power/mem_sleep` 仅支持 `[s2idle]`(无 S3 deep),该配置(EPYC+5.4 内核+消费级 GPU/NVMe)入睡后无可靠唤醒源 → 表现为"电源灯亮的硬冻结"。**为何断电前 96 天从未触发(考古定论,2026-11-17 查实)**:桌面环境是 **2026-08-12 09:05 apt 安装的**(zklink 用户同期在 tty1 物理控制台活动,经 ATEN KVM),装完机器**一直没重启过**,gdm3/空闲挂起策略处于休眠;**断电重启 = 装桌面后第一次开机**,greeter 首次上线、策略首次生效,于是每次开机 20 分钟即"冻死"。GUI 从无任何人登录过(gdm-password 全 boot 计数=0),SSH 活动也不重置 GUI 空闲计时——这是典型的"重启引爆数月前的休眠变更"。

| 时间 | 事件 | 证据 |
| --- | --- | --- |
| 00:44:41 | 公司断电(96 天长跑 boot 日志戛然而止) | sudo journal boot -3 终点 |
| ~01:05 | 来电,BIOS 通电自启 | wtmp |
| 01:08:15 | 开机;01:08:16 隧道恢复(容器陆续拉起中) | journal/跳板机 sshd |
| **01:28:19** | **空闲 20 分 04 秒 → 挂起#1**(开机起 20 分钟"半活"窗口结束) | `PM: suspend entry (s2idle)` |
| 01:28–09:38 | s2idle 睡死 **8h10m**(灯亮风扇转,ARP/softdog/隧道全部"死"——其实是在睡) | 无 `suspend exit` |
| 09:38 | 人工硬重启#1 → 09:44 全绿 | 本会话验证 |
| **10:00:48** | **挂起#2**(又是空闲 20 分钟) | `PM: suspend entry` |
| 10:05–10:10 | 检出失联;跳板机告警 cron 上线,**10:10:02 首条企微告警发出** | 本会话/跳板机 journal |
| 10:13:16 | 用户到场按键短暂唤醒;**10 秒后(10:13:26)因空闲早已超时立即再睡** | `suspend exit`→`entry` |
| ~10:14 | 长按电源硬关 → 10:15:09 开机 → ~10:21 全恢复,企微恢复通知自动发出 | journal/告警状态清空 |
| 10:22–10:30 | 两路子智能体并行取证,锁定 GNOME 空闲挂起 | 本会话 |
| **10:29:58** | **mask 四个睡眠 target + gdm/huanhua 空闲策略改 nothing**(赶在 ~10:36 的下一次挂起前) | 本会话 |
| 10:38+ | 跨过空闲死线仍存活、当前 boot suspend=0 = **根治** | 本会话实测 |

**影响**:公网入口 00:44–10:21 不可用约 **9 小时 36 分**(其间 1888 请求/1486×502,真实用户 6-8 个 IP,余为扫描器);内网同样全断;数据零损失。

**四大"谜团"的统一解释**:ARP 不应答=网卡睡了;softdog 不触发=s2idle 连定时器一起冻结;隧道零重连=睡着无出站流量;"开机 15~25 分钟才冻"=正是空闲 1200 秒。

## 6. IPMI 硬件看门狗部署细节(2026-11-17 由 softdog 升级而来)

**语义**:systemd PID1 每 150s 喂一次 `/dev/watchdog`(=ipmi_watchdog → Supermicro BMC),**PID1 连续 300s 喂不上 → BMC 侧独立硬复位**。比 softdog 强在**计时器跑在 BMC 芯片上、独立于主机 OS**:中断全死的深度挂死、甚至睡死(s2idle)它都能复位(softdog 这两类全瞎)。依然防不住断电(机器没电),断电靠 BIOS 自启+§6.6 告警兜底;睡眠靠 §6.5 mask 治本(看门狗只会把睡死变成复位循环,mask 才是不睡)。

配置三件(全在 192.168.110.221,经 `ssh hh2-prod` + sudo;system.conf.d 与 watchdog-arm.service 沿用 softdog 时代):

| 文件 | 内容 | 作用 |
| --- | --- | --- |
| `/etc/modprobe.d/ipmi-watchdog.conf` | `options ipmi_watchdog timeout=300 action=reset nowayout=0` | ⚠ **action 是字符串**(reset/none/power_cycle/power_off),传数字=modprobe 报 Invalid argument |
| `/etc/modules-load.d/ipmi-watchdog.conf` | `ipmi_si` + `ipmi_watchdog` | 开机自动加载(softdog 的两个配置文件已删) |
| `/etc/systemd/system.conf.d/10-watchdog.conf` | `[Manager]` `RuntimeWatchdogSec=300s` | PID1 喂狗(每 150s 一次) |

**验证**(⚠ ipmi_watchdog 不走 watchdog core 框架,**没有 `/sys/class/watchdog/` 条目**,identity/timeout 都看不了;验证走设备节点+BMC 侧):

```bash
ssh hh2-prod 'ls -l /dev/watchdog; cat /proc/misc | grep watchdog'   # 10:130,节点时间戳=模块加载时刻
ssh hh2-prod 'lsmod | grep -E "ipmi_watchdog|^softdog"'              # ipmi 在、softdog 无
ssh hh2-prod 'systemctl show -p RuntimeWatchdogUSec; sudo ls -l /proc/1/fd | grep watchdog'  # 5min + PID1 持有
ssh hh2-prod 'sudo ipmitool mc watchdog get'                          # Timer Is: Started/Running;Actions: Hard Reset;Initial 300
```
**活体证明**:装载后机器活过 300+ 秒即证明 PID1 在喂(没人喂 BMC 会在 300 秒整硬复位);Present Countdown 应在 ~150-300 区间周期性回满。

**活体换枪顺序**(再换回 softdog 或改超时同理):system.conf.d 改 0 → `daemon-reexec`(PID1 放下 fd)→ `modprobe -r` 旧模块 → `modprobe` 新模块 → system.conf.d 改 300s → `daemon-reexec`(PID1 接管)→ 验证。顺序错了 rmmod 会报 in use。

## 6.5 睡眠抑制(治本闸,2026-11-17 10:29 落地)

```bash
# 系统级硬闸:mask 后 GNOME/logind/任何组件都无法再触发挂起,立即生效+重启持久
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# GNOME 双保险:gdm(greeter)与真实桌面用户(huanhua)两侧空闲策略都改 nothing
for u in gdm huanhua; do
  for k in sleep-inactive-ac-type sleep-inactive-battery-type; do
    sudo -u $u dbus-launch gsettings set org.gnome.settings-daemon.plugins.power $k 'nothing'
  done
  sudo -u $u dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
done
# 验证:systemctl is-enabled suspend.target 应 masked;跨过 20 分钟空闲线仍存活
```

回滚:`systemctl unmask` + gsettings 还原(不建议)。**长期可选**:若这台机器不再需要当桌面用,`systemctl set-default multi-user.target` 彻底去 GUI。

## 6.6 跳板机侧失联告警(2026-11-17 10:05 落地,当天即实战验证)

- 位置:aliyun-swas 上 `/usr/local/bin/tunnel-alert.sh` + `tunnel-alert.service/.timer`(每分钟),webhook 凭据 `/etc/tunnel-alert/webhook.url`(root 600)。
- 语义:三口(12222/8081/18081)持续失联 **≥300s → 企微群告警**(滤掉隧道例行 30s 抖动);恢复自动发恢复通知;长故障每 6h 重复提醒。
- 实战记录:10:10:02 首条告警、~10:21 恢复通知,均送达。日志:`journalctl -u tunnel-alert.service`。

## 7. 历史钉子速查

- **无 sudo 的 `journalctl` 只能看到用户级碎片**(本事故初期"journal 终点 01:58/01:24"全是碎片假象)——读系统日志必须 `ssh hh2-prod 'sudo journalctl …'`,且**内核消息只有 sudo 视角可见**。
- 机器跟前处置顺序:先按键唤醒定性(§1 ③b),再决定硬重启;唤醒后先保睡眠抑制在位。
- 本机直连 `ssh file_service` 首次报 Host key verification failed → 加 `-o StrictHostKeyChecking=accept-new`。
- 跳板机 nginx 的 access.log 未轮转(400MB+),大范围 grep 前先按日期过滤。
- `kex_exchange_identification` 噪音 ≠ 隧道事件,判隧道只认 `Accepted publickey for tunnel` / session 行。
- 断电后来电"看着开着"≠系统活着;判死活永远以 §1 探针为准,别被电源灯骗。
