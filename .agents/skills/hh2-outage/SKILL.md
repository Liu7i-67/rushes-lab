---
name: hh2-outage
description: 内网素材服务器(192.168.110.221)断电/失联/挂死/挂起事故处理手册:一分钟判别→定位决策树→处置→恢复验证,含 2026-11-17 断电事故完整档案(GNOME 空闲挂起根因)、softdog 看门狗(300s)与跳板机企微告警 cron 部署细节。凡遇服务器打不开、公网入口 502、反向隧道断、ping 不通 110.221、公司断电/来电后要确认服务器状态等场景时使用——即使用户没说"事故"这个词。
---

# 内网服务器断电/失联事故处理手册

## 0. 全链路架构(一切判别的地基)

```
公网用户 ──→ 阿里云跳板机 aliyun-swas(47.108.196.211,不受公司断电影响)
              nginx :8080/:18080/:443 → 127.0.0.1:8081(dev)/18081(prod)
                        ↑ 反向 SSH 隧道(账号 tunnel;**受管服务=msdev user 单元 jump-tunnel.service,Restart=always/RestartSec=10s+enabled+Linger=yes,断线 10s 自动重连**)
内网用户 ──→ 内网服务器 192.168.110.221(:8090 dev / :80 prod,容器栈 ×24)
```

- **内网服务器唯一入站通道 = 反向隧道**(机器在 NAT 后,无公网、无 VPN)——隧道死 = 远程彻底无门。
- **服务器是一台带 GUI 的工作站型服务器**:default target=`graphical`,gdm3 + GNOME + RTX 3080 Ti,白天有人当桌面用。⚠ **任何"空闲即挂起/关机"类策略都可能在无人值守时段把它变假死**(2026-11-17 事故根因,已 mask,见 §5/§6.5)。
- 时区:内网服务器日志是 **UTC**,跳板机/本机是北京时间,对照时间线一律 +8。
- SSH 别名:`file_service`(msdev 直连,**无 sudo**)/`hh2-prod`(huanhua 免密 sudo,走隧道)——见 `~/.ssh/config`。

## 1. 一分钟判别(先跑这三条,别猜)

```bash
# ① 公网入口(本机直接跑):502 = 跳板机 nginx 活着但上游断(隧道死 **或** hh2 侧 poc-nginx 旧解析/上游容器死——先做 §2.5 分层定位再下结论);超时 = 跳板机/网络问题
curl -s -o /dev/null -m 8 -w "%{http_code}\n" http://47.108.196.211:8080/api/v1/auth/me   # 期望 401
# ② 隧道端口(跳板机侧):三口全无监听 = 隧道不在
ssh aliyun-swas 'ss -tln | grep -E ":(12222|8081|18081)\b"'
# ③ 隧道守护重连记录:断链时 ~10s 一次刷屏;**零记录 = 整机没电/挂死/睡着**(最强证据)
ssh aliyun-swas 'journalctl -u sshd --since "<事发日>" --no-pager | grep "for tunnel" | tail -20'
# ③b 服务器侧定性(可达时):挂起还是挂死,一条命令见分晓(必须 sudo,见 §7)
ssh hh2-prod 'sudo journalctl -b 0 -k --no-pager | grep -E "PM: suspend"'
# ④ 本机在公司且需区分「服务器死 vs 出口链路断」:agent 自连 WiFi 直连 .221 定性(见 §2.6,无需用户动手)
```

## 2. 定位决策树

| 证据组合 | 结论 | 依据 |
| --- | --- | --- |
| ②三口全无 + ③零重连记录 | **整机没电 / 挂死 / 挂起假死**(电源灯亮≠系统活着) | 守护正常时必在 10s 重试;睡着/挂死时出站全停 |
| 服务器可达 → ③b 有 `PM: suspend entry` 无 `exit` | **挂起假死**(按一下电源键/键盘通常能唤醒,但空闲超时未解除会再睡,唤醒后立刻做 §6.5 的 mask) | s2idle 入睡后无唤醒源 |
| ②缺端口 + ③有重连刷屏 | 服务器活着,隧道进程/网络单独出问题 | 重试说明 OS 在跑 |
| ①502 但 ②正常 | **不一定是隧道**——先做 §2.5 分层定位(502 错误页由哪层生成=故障在哪层);2026-11-19 实战:隧道正常,真凶=hh2 侧 poc-nginx-dev 持旧 IP 解析 | §2.5 |
| 公网通、仅内网不通 | 本机网段/网卡选择问题(见下方"双网卡"事实) | — |

**本机双网卡事实(2026-11-17 实测)**:运维机**常态下有线+WiFi 同时连接**——有线在 192.168.1.x 网段(**到不了服务器**),WiFi 拿 192.168.110.x(与服务器同段)。**直连内网服务器只能走 WiFi**,无需断开有线,显式绑定源地址已实测可通:`ping -S 192.168.110.14 192.168.110.221`。若 WiFi 拿到的地址不同,`ipconfig` 现查再绑。**内网 WiFi SSID=「服务器」,profile 已存密码,agent 可自连(§2.6)**。

**内网侧二层定位**(本机需在 110.x 网段):
`Reply from <本机IP>: Destination host unreachable` = **本机 ARP 解析失败,改网关/加路由无效,别动网络配置**。
全网段扫一遍(`seq 1 254 | xargs -P 64 -I@ ping -n 1 -w 400 192.168.110.@ >/dev/null 2>&1; arp -a | grep 192.168.110`):
百台主机有 MAC、唯独 .221 无条目 → 锁定服务器自身(挂死与挂起在此完全同貌,区分靠 ③b)。

## 2.5 公网 502 分层定位(2026-11-19 实战新增)

502 = 跳板机 nginx 活着、上游断,但**上游有四层**:跳板机 nginx → 隧道(8081/18081) → hh2 发布端口(8090 dev / 80 prod) → poc-nginx(±-dev) → ms-api(±-dev):8000。**先逐层 curl 拿应答码+错误页,别猜**:

```bash
# 跳板机→外网视角:同一端口不同路径分开测(nginx 按 location 分流,/ 正常 ≠ 全站正常)
curl -sS -o /dev/null -w '%{http_code} %{size_download}B\n' http://47.108.196.211:8080/                  # 302=这条链活着
curl -sS --max-time 8 http://47.108.196.211:8080/<故障路径> | head -c 200                                # 157B nginx 错误页=看下面三层
# hh2 侧逐层(经 ssh hh2-prod):
for p in 80 8080 8090; do printf "$p: "; curl -sS -o /dev/null -w '%{http_code} %{size_download}B' --max-time 6 http://127.0.0.1:$p/<同一故障路径>; echo; done
```

- **157B 的 nginx 502 页由哪台 nginx 生成 = 故障在它的上游**:跳板机错误页→隧道/hh2 断;`hh2:8090` 上的 157B 页=poc-nginx-dev 生成→它的上游(ms-api-dev)断。
- **头号陷阱:poc-nginx(±-dev) 持旧 IP 解析**。nginx 静态 proxy_pass 在配置加载时解析一次;**ms-api(ms-api-dev) 容器 restart/force-recreate/重建都可能换 IP**(2026-11-19 实证:普通 restart 也换),47h 未重启的 poc-nginx-dev 就持旧 IP → 它代理的路径全 502,而它本地自答的路径(/ 302、/auth/me 403)看起来"半好半坏"。**处方:凡动 ms-api/ms-api-dev 容器,一律连带 `docker restart poc-nginx poc-nginx-dev`**(restart 本身秒级,无窗口顾虑)。
- 隧道是否活的快速判据:跳板机 `ss -tln` 三口在 + hh2 发布端口有应答 = 隧道大概率没事;**隧道进程受 jump-tunnel.service 看护,断线 10s 自动重连——2026-11-19 的 502 事件中隧道从头到尾都是活的,勿条件反射怀疑隧道**。

## 2.6 本机自连 WiFi 直连服务器(agent 可自主执行,2026-11-20 实战)

跳板机失联 / 疑似公司出口断链时,**agent 无需用户动手即可把本机连上内网 WiFi 直连 .221 做分层定性**(前提:本机在公司,且 WiFi profile「服务器」已存密码——2026-11-20 实测):

```bash
netsh wlan connect name="服务器" interface="WLAN"          # 连接即 DHCP 拿 110.x(地址会变:.14/.30 都见过)
sleep 8; ipconfig | grep "110\."                            # 确认拿到 110.x 地址;现查现绑,勿沿用旧地址
ping -n 2 -w 1500 192.168.110.1                            # 先验网关:通=WiFi 链路活;不通=本机 WiFi 侧问题,别怪服务器
ping -S <本机110地址> -n 2 192.168.110.221                  # 双网卡下显式绑 WiFi 源(有线 1.x 抢路由时必绑)
ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new file_service 'hostname; docker ps -q | wc -l'  # 终点:24=容器全在
```

**定性结论**:
- **直连通**(ping/ssh 皆通)→ 服务器与内网无恙,故障在**公司出口链路或隧道侧**(2026-11-19 夜案:出口黑洞 2h13m,服务器全程无辜;配合跳板机 sshd 零 Accepted + 服务器侧 jump-tunnel 卡 `kex_exchange_identification: read: Connection timed out` 即可定案出口断链)。
- **网关通但 .221 ARP 无应答** → 服务器自身问题(挂死/挂起/断电),走 §2 决策树 + §1 ③b 定性。

**钉子(2026-11-20 实测)**:
1. **Ugreen USB WiFi 断开再连后可能「关联成功拿到 IP→几秒内掉线」**:现象=ipconfig 一度有 110.x,随后 ping 全超时且 `arp -a` 连网关条目都没了(WLAN 媒体已断开)。处置=**原命令再 connect 一次**即稳;**验证以 ping 网关为准,拿到 IP ≠ 链路稳定**。
2. `netsh wlan show interfaces` 连接后查询可能报「需要位置权限/错误 5」——**不必去开位置服务**,用 ipconfig+ping 验证即可。
3. `ipconfig | grep -A 6 "适配器 WLAN"` 抓 IPv4 偶尔落空(标题段紧跟空行),直接 `grep "110\."` 更稳。
4. 本法只覆盖「本机在公司」的情形;人不在公司时只能靠 §1 跳板机侧探针远程判别。

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

## 8. 操作失误红线(2026-11-19 实战踩坑,禁止再犯)

以下每条都是当天真实犯过并造成实际损失/排查绕路的,动手前对照:

1. **杀隧道进程前必看归属——它就是你的 ssh 会话载体**。hh2 的唯一入站通道是反向隧道,`kill` 掉 `ssh -N -R` 子进程=当场切断自己(当天两次把会话杀断、把验收命令截断在 kill 处)。kill 前先 `cat /proc/<pid>/cgroup` 看归属;验证/断言命令一律放 kill **之前**或重连之后。
2. **禁止用 `systemctl --user -M msdev@` 探查用户单元**——polkit 下**静默返回空列表**,据此断言"隧道无看护"是本次最大误诊(实际 jump-tunnel.service 看护完备)。正确姿势:`sudo -u msdev XDG_RUNTIME_DIR=/run/user/1003 systemctl --user ...`,或 `cat /proc/<pid>/cgroup` 直接判归属。**探查工具返回空 ≠ 东西不存在,先怀疑探查姿势**。
3. **禁止未分层定位就动手换部件**。502 事件中没拿错误页定位就杀隧道(隧道全程正常),白制造一次真中断+绕路半小时。顺序:§2.5 逐层 curl → 定位层 → 处置。
4. **测试/排查 SQL 一律打 ms-db-dev,生产集群 ms-db 只读**。两套 compose 的 DB 服务都叫 `ms-db`,**容器网络别名在各自己网络内解析**——ms-api-dev 容器里的 `ms-db` = ms-db-dev 容器。动手前先 `docker exec <api容器> env | grep DB_URL` 确认,再决定在哪个容器里跑 psql。
5. **禁止 psql `-c` 多语句混排**:多条语句在单隐式事务里,**最后一句报错=整体回滚**(本次 DELETE+SELECT 报错→"删了又复活"假象,排查绕路)。清理/写入语句单独一个 `-c` 跑;确需多语句显式 `BEGIN;…COMMIT;`。
6. **调试注入必须记收尾清单**:往共享容器文件里注入调试日志(当天 VIPDEBUG 行)、往测试库插临时数据(当天 repro 行污染出 22 failed 假象),都必须当场登记,收尾逐一剔除+md5 对账;"想着等下回滚"不算数。
7. **修容器内 tests 必须整目录 docker cp**(先 `rm -rf` 再传完整目录)——只传改动文件会把整套测试弄残(当天 import 全炸)。
