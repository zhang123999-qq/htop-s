# htop-s 使用手册

> Linux 服务器实时监控终端面板 · 部署 / 指令 / 排错
> 版本：v2.0　|　适用：Debian / Ubuntu / CentOS / Rocky / Alma / Alpine

---

## 目录

1. [5 分钟上手](#1-5-分钟上手)
2. [三种部署方式](#2-三种部署方式)
3. [启动、停止与开机自启](#3-启动停止与开机自启)
4. [面板逐区解读](#4-面板逐区解读)
5. [命令全表](#5-命令全表)
6. [键盘操作](#6-键盘操作)
7. [流量配额与 nftables 计数](#7-流量配额与-nftables-计数)
8. [告警配置](#8-告警配置)
9. [汇总报告](#9-汇总报告)
10. [日常巡检 SOP](#10-日常巡检-sop)
11. [故障排查 FAQ](#11-故障排查-faq)
12. [卸载](#12-卸载)

---

## 1. 5 分钟上手

### 只想看一眼

```bash
scp htop-s root@你的服务器:/usr/local/bin/htop-s
ssh root@你的服务器
chmod +x /usr/local/bin/htop-s
htop-s
```

完事。没有安装步骤、没有依赖包、不需要联网。

### 想让服务器 7×24 自动盯着

```bash
sudo htop-s --install
```

一条命令搞定：装到系统、配开机自启、创建流量计数、初始化配置。
以后 SSH 上去敲 `htop-s` 就能看实时画面。

### 先确认这台机器支持什么

```bash
htop-s --check
```

会逐项探测数据源和权限，输出一份兼容性报告。**第一次上某台机器，先跑这个。**

---

## 2. 三种部署方式

### 2.1 裸部署（推荐，不需要 root）

```bash
scp htop-s user@server:/tmp/
ssh user@server
chmod +x /tmp/htop-s
/tmp/htop-s
```

单个文件，拷过去就能跑。适用于：临时排查、非 root 账号、不想改动系统。

**非 root 能用多少功能？**

| 功能 | 非 root |
|---|---|
| CPU / 内存 / 磁盘 / 网卡 / TCP 计数 | 全部可用 |
| 其他用户的进程端口映射 | 显示 `?` |
| nftables 流量计数 | 不可用，回退 `/proc/net/dev` |
| 开机自启 | 不可用（需写 systemd） |

### 2.2 系统安装（需要开机自启时用）

```bash
sudo htop-s --install
```

安装后文件分布：

| 内容 | 位置 |
|---|---|
| 可执行文件 | `/usr/local/bin/htop-s` |
| 配置 | `/etc/htop-s/config` |
| 状态数据 | `/var/lib/htop-s/state` |
| 采集日志 | `/var/log/htop-s/collect-YYYY-MM-DD.csv` |
| 告警日志 | `/var/log/htop-s/alert-YYYY-MM-DD.log` |
| systemd 服务 | `/etc/systemd/system/htop-s.service` |

想让 SSH 登录时看到一句提示，加 `--with-motd`：

```bash
sudo htop-s --install --with-motd
```

登录时会显示「输入 htop-s 查看服务器实时监控」。默认不装，避免污染登录环境。

### 2.3 升级

```bash
scp htop-s.new root@server:/tmp/htop-s
ssh root@server
/tmp/htop-s --upgrade
```

升级前会自动做语法检查，**语法不过就不会覆盖**，同时备份旧版到
`/usr/local/bin/htop-s.bak`。出问题可以：

```bash
sudo cp /usr/local/bin/htop-s.bak /usr/local/bin/htop-s
```

---

## 3. 启动、停止与开机自启

### 3.1 日常操作

| 你想做什么 | 命令 |
|---|---|
| 看实时面板 | `htop-s` |
| 看服务整体状态 | `htop-s --status` |
| 停止后台采集 | `sudo htop-s --stop` |
| 启动后台采集 | `sudo htop-s --start` |
| 重启后台采集 | `sudo htop-s --restart` |
| 看采集日志 | `htop-s --log` |
| 看告警记录 | `htop-s --alert` |

### 3.2 开机自启是怎么工作的

`--install` 会注册 systemd 服务 `htop-s.service`，设为 `enable`，
所以**服务器重启后会自动在后台开始采集，不需要你登录**。

服务在 `network-pre.target` 之后启动，尽量早地开始统计流量，减少开机窗口期的丢量。

**面板与后台服务的关系**：

- 两者互相独立。后台服务挂了，`htop-s` 面板照样能用，只是流量配额区显示"未启用"
- 面板不写状态文件，后台服务独占写。所以同时开多个面板窗口是安全的
- 后台服务有资源上限（最多 10% 单核、64MB 内存），**不会拖慢服务器**

### 3.3 确认自启真的生效了

```bash
systemctl is-enabled htop-s    # 应输出 enabled
systemctl is-active htop-s     # 应输出 active
```

重启一次服务器再验证最稳妥：

```bash
sudo reboot
# 重新登录后
htop-s --status
```

---

## 4. 面板逐区解读

从上到下依次是：

### 4.1 主机信息

主机名、当前时间、已运行时长、CPU 核数、发行版 / 内核 / 架构。

### 4.2 系统概况

IP、登录用户数、僵尸进程数、系统负载。

**负载怎么看**：`1.24 / 0.98 / 0.71 (0.16/核)` —— 括号里是「负载 ÷ 核数」，
这个数字才有意义：

| 归一值 | 含义 |
|---|---|
| < 0.7 | 轻松 |
| 0.7 ~ 1.0 | 忙但正常 |
| > 1.0 | 有任务在排队等 CPU |
| > 2.0 | 严重过载，触发告警 |

**别直接看裸负载**：8 核机器负载 6.0 完全正常，1 核机器负载 6.0 就是灾难。

### 4.3 CPU

```
CPU  ████████░░░░░░░░░░░░ 42.3%   user 31.2 sys 8.4 io 2.7 steal 0.0
```

| 分项 | 含义 | 高了说明什么 |
|---|---|---|
| user | 用户态 | 应用程序在算 |
| sys | 内核态 | 系统调用频繁（IO 密集、频繁 fork） |
| io | IO 等待 | **磁盘慢**，CPU 其实在等盘 |
| **steal** | 被宿主机抢占 | **VPS 专用**：> 5% 说明邻居在抢你的 CPU |

**steal 是云服务器最该看的指标**。物理机恒为 0。如果你没跑什么负载但 CPU 很高、
steal 也不高，考虑是不是被挖矿了（看 TOP 进程）。

按 `1` 展开每核视图。**单核跑满、其他核空闲**是典型现象，通常说明程序是单线程的。

### 4.4 内存

```
MEM  ██████████░░░░░░░░░░ 51.2%  8.1G/15.8G · Cached 3.2G · Swap 0.4/2.0G · 换页 in 0 out 0 页/s
```

- **已用** = 总量 − 可用，不是「总量 − 空闲」。Linux 会用空闲内存做缓存，只看"空闲"会误判
- **Cached** 高是好事，说明缓存命中率高
- **Dirty / Writeback** 持续高 → 磁盘写入跟不上
- **换页 in/out**：这两个数字持续非零，说明**内存不够在用 Swap**，性能会断崖式下降

**关于 Swap**：用了不等于有问题（不常用的大页被换出去是正常的），
但如果**使用率高 + 换页速率持续非零**，就是真缺内存了。

### 4.5 磁盘容量与 IO

```
DISK / 64% 32G/50G · inode 12% · 读 2.1MB/s 写 480KB/s · IOPS 320
```

- **inode**：文件数量配额。**磁盘还有空间但写不进去**，十有八九是 inode 满了
- **IOPS / 读写速率**：判断磁盘是否成为瓶颈
- 磁盘利用率接近 100% → IO 饱和

### 4.6 网络

```
NET  eth0 10.0.0.21
  累计 ↓1.24TB ↑386GB
  实时 ↓ 4.31MB/s  ↑ 812KB/s   峰值 ↓22.4MB/s · 错误 0 · 丢包 0
  ↓ ▁▂▅▇█▆▃▂▁▂▄▆█▇▅▂▁▁▂▃▅▇▆▄▂▁▁▂▄▆▇█▆▄▂▁▂▃▅▇▆▄▂
  ↑ ▁▁▂▂▃▃▄▄▅▅▆▆▇▇██▇▆▅▄▃▂▁▁▂▂▃▃▄▄▅▅▆▆▇▇██▇▆▅▄▃▂
```

- **累计**：网卡开机以来的总收发量
- **实时**：当前上下行带宽
- **峰值**：本次运行期间的最高值
- **错误 / 丢包**：**这两个数字只要持续增长就是问题**。错误增长多为物理链路/驱动问题；
  丢包增长说明带宽打满或缓冲区溢出
- **曲线**：一眼看出流量是平稳还是突发。突刺说明有大文件传输或攻击

多网卡用 `-I eth0,eth1` 会求和显示。

### 4.7 流量配额

```
本月 412GB / 1024GB  ████░░░░░░ 40%  预计月底 780GB
```

| 显示 | 含义 |
|---|---|
| 本月已用 / 配额 | 当前计量周期内的流量 |
| 百分比条 | 用量进度 |
| 预计月底 | 按当前日均用量线性外推 |
| **数据不完整** | 服务器重启过，且未启用 nftables 计数，重启期间流量丢失 |

**预计月底超过 100% 就该处理了**，别等账单出来。

### 4.8 TCP / UDP

```
TCP  218 连接  EST 46 · TIME_WAIT 152 · SYN_RECV 3 · CLOSE_WAIT 11
  重传 0.4% · ListenDrop 0 · 半连接溢出 0 · conntrack 312/65536
UDP  37  InErr 0 · RcvbufErr 0
监听 0.0.0.0:443 nginx   0.0.0.0:22 sshd
```

| 指标 | 正常 | 异常信号 |
|---|---|---|
| ESTABLISHED | 业务正常连接数 | 突然暴涨 → 可能是攻击或连接泄漏 |
| **TIME_WAIT** | 几万以内正常 | 超过 30000 需关注，说明短连接过于频繁 |
| **SYN_RECV** | 接近 0 | **上百就危险**：SYN Flood 攻击或端口扫描 |
| **CLOSE_WAIT** | 接近 0 | **超过几百就是程序 bug**：代码没关连接 |
| 重传率 | < 1% | > 5% 网络质量差 |
| ListenDrop / 半连接溢出 | 0 | 非零说明应用来不及处理新连接 |
| conntrack | < 80% | 接近上限会导致**新连接直接失败** |

**CLOSE_WAIT 是最有价值的排查信号** —— TIME_WAIT 是正常回收，CLOSE_WAIT 是应用漏了
`close()`，长时间积累会耗尽文件描述符。

按 `p` 展开「端口 → 进程」映射，用来回答「443 端口是谁在监听」。

### 4.9 进程

```
 PID    CPU%   MEM%   THR  状态  CMD
 8821   38.1   12.4   16   R    node /app/server.js
  902    0.0    8.8    1   D    kworker/u8:2  ← IO 阻塞
```

- **CPU% 是瞬时值**（两次采样的差值），不是进程生命周期平均值，所以能真实反映当前占用
- **状态**：`R` 运行、`S` 睡眠、`D` **不可中断睡眠**、`Z` 僵尸、`T` 停止、`I` 空闲
- **D 状态会红色高亮**。它意味着进程卡在 IO 上无法响应，是「服务器假死」最典型的信号。
  看到 D 状态：检查磁盘是否故障、NFS 是否挂死

按 `c`/`m`/`n`/`i` 切换排序（CPU / 内存 / 网络 / IO）。

---

## 5. 命令全表

### 运行与显示

| 命令 | 说明 |
|---|---|
| `htop-s` | 进入实时面板（默认 2 秒刷新） |
| `htop-s -i 5` | 改成 5 秒刷新（范围 1~30） |
| `htop-s -I eth0` | 指定监控网卡 |
| `htop-s -I eth0,eth1` | 多网卡合并统计 |
| `htop-s -e` | 英文界面 |
| `htop-s -a` | ASCII 模式（终端不支持方块字符时） |
| `htop-s -n` | 输出一次快照就退出（排障 / 配合 grep） |
| `htop-s -m` | 精简模式：只显示流量和连接 |
| `htop-s -p` | 显示「端口 → 进程」映射（非交互场景用；需 root 才能看到其他用户的进程） |

### 部署与生命周期

| 命令 | 说明 |
|---|---|
| `sudo htop-s --install` | 安装 + 开机自启 + 启用流量计数 |
| `sudo htop-s --install --with-motd` | 同上，另加登录提示 |
| `sudo htop-s --uninstall` | 卸载服务与脚本（**保留**日志和流量数据） |
| `sudo htop-s --uninstall --purge` | 彻底清理，含日志、状态、nft 表 |
| `sudo htop-s --upgrade` | 升级已安装版本 |
| `sudo htop-s --start` | 启动后台采集 |
| `sudo htop-s --stop` | 停止后台采集（**保留**流量计数，避免断点） |
| `sudo htop-s --restart` | 重启后台采集 |
| `htop-s --status` | 服务 / 进程 / 日志 / 配额 一览 |
| `htop-s --daemon` | 前台跑采集循环（一般由 systemd 调用） |

### 数据查询

| 命令 | 说明 |
|---|---|
| `htop-s --log` | 看采集日志，默认最近 30 行 |
| `htop-s --log 200` | 看最近 200 行 |
| `htop-s --alert` | 看告警记录，默认 30 行 |
| `htop-s --today` | 今日汇总报告 |
| `htop-s --month` | 本月汇总报告（含配额预测） |
| `htop-s --history 12` | 最近 12 个周期的流量归档 |
| `htop-s --export` | 当前快照导出 CSV 到 stdout |

### 配置

| 命令 | 说明 |
|---|---|
| `htop-s --quota 1024G` | 设置月流量配额（`0` = 不限） |
| `htop-s --reset-day 1` | 计量周期起始日（1~28） |
| `htop-s --keep 30` | 日志保留天数 |
| `htop-s --iface eth0` | 持久化默认网卡 |
| `htop-s --config` | 显示当前生效配置 |
| `htop-s --acct status` | 查流量计数模式 |
| `htop-s --acct off` | 关闭 nftables 计数（回退 /proc 模式） |

### 诊断

| 命令 | 说明 |
|---|---|
| `htop-s --check` | **环境自检，第一次上机器必跑** |
| `htop-s --selftest` | 内置自测 |
| `htop-s --test-alert` | 发一条测试告警 |
| `htop-s -V` | 版本号 |
| `htop-s -h` | 帮助 |

---

## 6. 键盘操作

| 键 | 功能 |
|---|---|
| `q` / `Ctrl-C` | 退出（终端自动恢复原样） |
| **空格** | 暂停 / 继续刷新（暂停后仍可切换视图） |
| `r` | 立即刷新一次 |
| `c` | 进程按 CPU 排序（默认） |
| `m` | 进程按内存排序 |
| `n` | 进程按网络连接排序 |
| `i` | 进程按磁盘 IO 排序（需 root） |
| `1` | 展开 / 收起每核视图 |
| `p` | 展开 / 收起「端口 → 进程」映射 |
| `+` / `-` | 刷新间隔 ±1 秒 |
| `s` | 把当前快照存入日志 |
| `?` / `h` | 帮助浮层 |

**暂停键很有用**：看到异常数值想仔细看时，按空格冻结画面，慢慢分析。

---

## 7. 流量配额与 nftables 计数

### 7.1 两种统计模式

| 模式 | 服务器重启后 | 需要 root |
|---|---|---|
| **增强模式**（nftables） | 流量**不丢**，跨重启连续累计 | 是 |
| **基础模式**（/proc/net/dev） | 重启期间流量**丢失**，显示"数据不完整" | 否 |

`--install` 时如果检测到 `nft` 命令且是 root，会自动启用增强模式。

### 7.2 为什么后台进程重启不丢数据

这里有个容易混淆的点：

- **只是 htop-s 服务重启**（服务器没重启）→ 网卡计数器仍在内存里，**完全续算，不丢数据**
- **服务器整个重启** → 网卡计数器清零 → 基础模式下这段就丢了

所以基础模式只有在**服务器重启**时才有缺口，日常服务重启不受影响。

增强模式用 nftables 在内核里计数，并且每次采样都把数值落盘，
即使服务器重启，重启前的量已经保存，不会归零。

### 7.3 nftables 会不会影响我的防火墙？

**不会。** 设计上严格遵守：

1. 只新建一个**独立的表** `inet htop_s`，**完全不动你已有的任何规则**
2. 自建链的策略是 `accept`，里面**只有计数语句，没有任何放行/拒绝动作**
3. 不执行 `flush ruleset`，不碰 iptables 兼容表
4. 卸载时会把自建表完整删除，系统恢复到安装前状态

它做的事就是：在数据包进出网卡的必经路径上挂一个计数器。**不改变任何流量的命运。**

验证：

```bash
sudo nft list table inet htop_s     # 看它长什么样
htop-s --acct status                # 看当前模式
```

### 7.4 配置配额

```bash
htop-s --quota 1024G          # 月流量 1TB
htop-s --quota 500G           # 500GB
htop-s --quota 2T             # 2TB
htop-s --quota 0              # 不限额
htop-s --reset-day 1          # 每月 1 日重置（默认）
htop-s --reset-day 15         # 每月 15 日重置（对齐账单日）
```

支持的容量后缀：`K` `M` `G` `T`（不区分大小写）。

**如果你买的是按流量计费的 VPS，这个功能能救命** —— 超流量通常会被限速或额外扣费。

### 7.5 预估怎么算

```
日均用量 = 本周期已用 / 已过天数
预计月底 = 日均用量 × 本周期总天数
```

如果预计月底超过配额 80%，面板会用醒目颜色提示，同时触发告警。

**注意**：周期开始不满半天时不会显示预估，因为样本太少会算出荒谬的值。

---

## 8. 告警配置

### 8.1 默认告警规则

| 指标 | 阈值 | 持续 |
|---|---|---|
| CPU 使用率 | ≥ 90% | 3 次采样 |
| 内存使用率 | ≥ 90% | 3 次采样 |
| Swap 使用率 | ≥ 50% 且有换页 | 3 次采样 |
| 磁盘使用率 | ≥ 90% | 立即 |
| inode 使用率 | ≥ 90% | 立即 |
| 负载 / 核数 | ≥ 2.0 | 3 次采样 |
| conntrack 占用 | ≥ 80% | 立即 |
| SYN_RECV | ≥ 100 | 立即 |
| TIME_WAIT | ≥ 30000 | 立即 |
| CLOSE_WAIT | ≥ 500 | 3 次采样 |
| TCP 重传率 | ≥ 5% | 3 次采样 |
| 网卡错误/丢包增量 | > 0 | 3 次采样 |
| 月流量 | ≥ 配额 80% / 100% | 立即 |
| D 状态进程 | 存在 | 5 次采样 |
| 断网 | ping 网关失败 | 3 次采样 |
| OOM 事件 | 增量 > 0 | 立即 |

### 8.2 在哪看告警

```bash
htop-s --alert          # 最近 30 条
htop-s --alert 200      # 最近 200 条
```

原始文件：`/var/log/htop-s/alert-YYYY-MM-DD.log`

格式示例：

```
2026-09-17 09:12:33 [CRIT] [syn] SYN_RECV=142 (阈值 100) 疑似 SYN Flood，TOP 来源: 203.0.113.7 (86)
2026-09-17 09:15:02 [WARN] [cpu] CPU=92.3% 已持续 15 秒，TOP 进程: 8821 node (38.1%)
2026-09-17 09:20:11 [INFO] [cpu] 已恢复 (当前 34.1%)
```

每条告警都附带**诊断上下文**（TOP 来源 IP、TOP 占用进程），不用再去别处查。

### 8.3 想让告警推到手机？

默认只写本地日志（零依赖）。但留了扩展口子 —— 配置一条命令即可接入企业微信、钉钉、
Telegram 等任意通道。

编辑 `/etc/htop-s/config`：

```
notify_cmd=curl -s -X POST 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=你的KEY' \
  -H 'Content-Type: application/json' \
  -d '{"msgtype":"text","text":{"content":"服务器告警: $ALERT_TEXT"}}'
```

告警内容会通过管道传入这条命令（也可用 `$ALERT_TEXT` 变量引用）。

测试连通性：

```bash
htop-s --test-alert
```

**提示**：命令里如果含单引号，注意在配置文件中的转义。不确定就先在 shell 里手测通再填。

### 8.4 调整阈值

在 `/etc/htop-s/config` 中按需覆盖：

```
alert_cpu=90
alert_mem=90
alert_disk=90
alert_syn=100
alert_load=2.0
```

改完 `htop-s --restart` 生效。

### 8.5 告警抑制

同一规则触发后 **10 分钟内不重复推送**，避免刷屏。恢复时会补一条「已恢复」记录。

---

## 9. 汇总报告

### 9.1 今日报告

```bash
htop-s --today
```

输出包含：

- 总出入流量、峰值带宽及发生时间
- 平均负载、峰值负载
- 告警次数与 TOP 告警规则
- 连接数峰值、平均

用途：**每天早上花 10 秒扫一眼，知道昨天夜里服务器发生了什么**。

### 9.2 本月报告

```bash
htop-s --month
```

在今日报告基础上，额外包含：

- 本月累计流量 / 配额 / 使用率
- 日均用量与月末预测
- 与上月对比

用途：**流量配额管理**，以及月度运维汇报。

### 9.3 历史归档

```bash
htop-s --history 12
```

列出最近 12 个计量周期的流量记录，用于长期容量规划。

---

## 10. 日常巡检 SOP

### 10.1 每天早上（30 秒）

```bash
htop-s --today      # 夜里发生了什么
htop-s --alert      # 有没有告警
htop-s --status     # 服务还活着吗
```

### 10.2 感觉服务器慢时（1 分钟）

1. 敲 `htop-s` 进面板，**先看负载归一值**（括号里那个数）
2. 超过 1.0 → 切到 CPU 视角
   - 按 `c` 看 TOP 进程，谁在吃 CPU
   - 看 `steal`，如果是 VPS 且 steal 高 → 宿主机问题，联系服务商
3. 归一值不高但就是卡 → **看磁盘 IO 和 D 状态进程**
   - 磁盘利用率接近 100% → IO 瓶颈
   - 有进程是 D 状态 → 磁盘故障或 NFS 挂死
4. 内存满 → 看 Swap 和换页速率，持续换页就是真缺内存

### 10.3 怀疑被攻击时

1. 看 `SYN_RECV` 是否飙高 → SYN Flood
2. 看 ESTABLISHED 数量与 TOP 来源 IP
3. 按 `p` 展开端口映射，确认监听的服务
4. 看网络曲线是否突刺 → 大流量攻击

### 10.4 磁盘莫名的满

**先查 inode**。面板磁盘区有 `inode 12%` 这一项。如果 inode 接近 100%，
说明文件数量太多（小文件、日志碎片），删大文件没用，要找文件数最多的目录：

```bash
for d in /var/* /home/*; do echo "$(find $d -xdev 2>/dev/null | wc -l) $d"; done | sort -rn | head
```

### 10.5 例行容量评估

```bash
htop-s --month       # 流量趋势
htop-s --history 6   # 半年来每月用量
```

---

## 11. 故障排查 FAQ

### Q1. 提示 "bash: htop-s: command not found"

没装到 PATH 里。要么用完整路径运行，要么：

```bash
sudo cp htop-s /usr/local/bin/ && sudo chmod +x /usr/local/bin/htop-s
```

### Q2. 某个分区显示 `N/A`

对应数据源在这台机器上不可用。跑 `htop-s --check` 看到底缺什么。

常见情况：

| 显示 N/A 的项 | 原因 |
|---|---|
| 温度 | 虚拟机通常没有热传感器，**正常现象** |
| conntrack | 内核模块未加载 |
| OOM 次数 | 内核版本太老 |
| 读/写速率 | 无权限读盘或虚拟磁盘 |
| 端口 → 进程 | 非 root，只能看到自己的进程 |

### Q3. 提示 "需要 root"

这些功能需要 root：写 systemd、创建 nftables 表、看其他用户的进程端口映射。

```bash
sudo htop-s --check      # 看清楚哪些需要 root
```

### Q4. 流量统计显示 "数据不完整"

说明**服务器重启过**，而当前用的是基础模式（`/proc/net/dev`），重启期间的流量无法追溯。

解决：启用增强模式。

```bash
sudo htop-s --acct on
htop-s --acct status
```

### Q5. 面板刷新很慢 / 有卡顿

先确认连接数规模。如果服务器有上万连接，基础刷新会有压力。

```bash
htop-s -i 5        # 拉长刷新间隔
htop-s -m          # 用精简模式，只显示流量和连接
```

如果始终很慢，跑 `htop-s --check` 反馈结果。

### Q6. 退出后终端花屏 / 光标不见了

正常退出（`q`）会自动恢复。如果因为异常（比如 SSH 掉线）导致花屏：

```bash
reset
# 或者
stty sane
```

### Q7. 方块字符显示成乱码

终端没有 UTF-8 支持。

```bash
htop-s -a          # ASCII 模式
```

### Q8. 开机自启没生效

```bash
systemctl is-enabled htop-s     # 应为 enabled
systemctl status htop-s         # 看报错
journalctl -u htop-s -n 50      # 看服务日志
```

如果显示 disabled：

```bash
sudo systemctl enable htop-s
```

### Q9. nftables 计数没数据

```bash
htop-s --acct status            # 确认模式
sudo nft list table inet htop_s # 看规则是否存在
sudo htop-s --ensure-acct       # 幂等重建
```

如果这台机器用的是 iptables 传统后端、没装 `nft` 命令，增强模式不可用，
会自动回退基础模式 —— 这是预期行为，不是故障。

### Q10. 日志占太多磁盘

```bash
du -sh /var/log/htop-s/
htop-s --keep 7          # 改成只保留 7 天
```

日志按天切分，非当日文件会自动 gzip 压缩，单日也有大小上限。

### Q11. 我想改网卡

```bash
htop-s -I eth1                 # 临时用
htop-s --iface eth1            # 永久改
sudo htop-s --restart
```

服务器换了网卡名字（比如从 `eth0` 变成 `ens18`），流量计数会按网卡名分别记录，
**不会串数据**，但需要在配置里改成新名字。

### Q12. 多个面板同时开着会有问题吗

不会。面板只读取状态，不写入，多开是安全的。

### Q13. 会不会拖慢服务器

不会。设计上有三重保障：

1. 分帧调度：每 2 秒只算该算的，磁盘容量这种慢指标 60 秒才算一次
2. 一次采样批量解析：不反复 fork 外部命令
3. 系统安装时限制了资源上限（最多 10% 单核、64MB 内存）

实测空闲服务器上占用 < 1% CPU。

### Q14. 想把它接到脚本或监控系统里

交互面板需要终端，不能直接管道输出：

```bash
htop-s | grep tcp        # 报错: 交互面板需要终端
```

非交互场景用这两个：

```bash
htop-s -n                # 单次快照, 纯文本输出
htop-s --export          # 结构化 CSV, 便于程序解析

# 例如塞进自己的采集脚本
rx=$(htop-s --export | awk -F, '$1=="net_rx_bps"{print $2}')
```

### Q15. 服务器上没有 systemd（容器 / OpenVZ）

`--install` 会提示无法安装开机自启，但脚本本身仍可用。手动后台运行：

```bash
nohup htop-s --daemon >/dev/null 2>&1 &
```

想让它跟着容器主进程起，把它加进 entrypoint 脚本即可。

---

## 12. 卸载

### 保留数据（推荐）

```bash
sudo htop-s --uninstall
```

会停止并移除服务、删除 `/usr/local/bin/htop-s`，
**保留**日志、流量数据和配置，方便以后重装。

### 彻底清理

```bash
sudo htop-s --uninstall --purge
```

额外删除：

- `/var/lib/htop-s/`（状态与流量数据）
- `/var/log/htop-s/`（所有日志）
- `/etc/htop-s/`（配置）
- `inet htop_s`（nftables 表，防火墙恢复原状）

### 手动确认清理干净

```bash
ls /usr/local/bin/htop-s 2>/dev/null
systemctl status htop-s 2>/dev/null
sudo nft list table inet htop_s 2>/dev/null
```

三条命令都无输出即清理完成。

---

## 附：一页速查

```
部署      scp htop-s root@server:/usr/local/bin/ && chmod +x
自检      htop-s --check
安装      sudo htop-s --install
查看      htop-s
配额      htop-s --quota 1024G --reset-day 1
今日      htop-s --today
告警      htop-s --alert
状态      htop-s --status
卸载      sudo htop-s --uninstall

面板键位  q退出 · 空格暂停 · c/m/n/i排序 · 1每核 · p端口 · ?帮助
```
