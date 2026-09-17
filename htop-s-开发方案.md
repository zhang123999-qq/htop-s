# htop-s 开发方案

> Linux 服务器实时监控终端面板 · 开发规格说明书
> 版本：v2.0 设计稿　|　状态：待开发　|　更新：2026-09-17

---

## 0. 文档说明

本文是 `htop-s` 的**实现规格**，不是使用说明。使用方式见《htop-s 使用手册》。

本文所有设计决策均为**已确认项**，实现时不得自行偏离；如需变更，先改本文再改代码。

---

## 1. 项目概述

### 1.1 目标

为多台 Linux 服务器提供一个**单文件、零依赖、SSH 直连可用**的实时监控面板，覆盖 CPU、内存、磁盘、网络流量、TCP/UDP 连接和进程六大维度，并具备后台常驻采集、开机自启、流量配额统计和阈值告警能力。

### 1.2 定位

- 交互形态：**终端 TUI**，htop 风格，纯 Shell 渲染，不做网页、不依赖 Web 服务
- 使用方式：SSH 登录后敲 `htop-s` 即用
- 部署形态：单文件可执行，`scp` 过去 `chmod +x` 即可跑（见 §14）

### 1.3 非目标

| 不做 | 原因 |
|---|---|
| Web 界面 / HTTP 服务 | 用户明确排除；且会引入端口暴露风险 |
| 历史数据可视化图表 | 靠 `--today` / `--month` 文本汇总替代 |
| 多机集中管理 | 每台机器独立运行，不引入中心端 |
| 修改或接管系统防火墙策略 | 仅新增独立计数表，绝不动用户规则 |
| 支持 OpenWrt（busybox ash） | 兼容基线定为 bash 3.2+，见 §2 |

### 1.4 与旧版的关系

现有 `F:\tcp\htop-s`（约 800 行）**不可运行**，存在 13 处缺陷（见 §15.1）。本次为**重构**而非修补：保留其数据源选型思路和整体分区结构，重写调度、采集、渲染三层。

---

## 2. 设计决策基线（已锁定）

| 项 | 决策 | 影响 |
|---|---|---|
| 目标环境 | 多台混合：Debian / Ubuntu / CentOS 7 / Alpine | 必须做能力探测与回退 |
| 兼容基线 | **bash 3.2+**，放弃 OpenWrt | 禁用 bash4 语法，见 §4.1 |
| 依赖策略 | **纯 bash + awk + coreutils，零外部依赖** | 全部数据来自 `/proc` `/sys` |
| 数据源 | 自解析 `/proc`，**不用 `ss` / `netstat` / `ps` / `free` / `iostat`** | 性能提升一个数量级 |
| 流量统计 | **nftables 计数增强**，无 nft 时回退 `/proc/net/dev` | 跨重启不丢流量 |
| 告警通道 | **只写本地告警日志**，保留 `NOTIFY_CMD` 扩展钩子 | 零依赖但可扩展 |
| 交付范围 | 一次做到位：面板 + 配额 + 告警 + 日志 + 汇总 | 单文件约 1800~2200 行 |

---

## 3. 总体架构

### 3.1 分层

```
┌─────────────────────────────────────────────────────────┐
│  L5 输出层  备用屏缓冲 · 宽度自适应 · 颜色降级 · 双语文案  │
├─────────────────────────────────────────────────────────┤
│  L4 渲染层  12 个分区 · 进度条 · 曲线 · 阈值配色          │
├─────────────────────────────────────────────────────────┤
│  L3 缓存层  分帧调度器 · 各帧结果驻留 · 跨帧差分状态        │
├─────────────────────────────────────────────────────────┤
│  L2 聚合层  awk 一次性完成多键聚合，shell 只拼字符串       │
├─────────────────────────────────────────────────────────┤
│  L1 采集层  读 /proc /sys · 能力探测 · 回退链             │
└─────────────────────────────────────────────────────────┘
```

**关键约束：L2 必须把「同一次采样的全部派生指标」在一次 awk 调用内算完。**
这是零依赖方案下的性能命门——shell 每 fork 一次约 1~3ms，若每个指标各调一次 awk，单帧就会累积上百次 fork。

### 3.2 进程模型

`htop-s` 有两种运行形态，**职责严格分离**：

| 形态 | 启动方式 | 职责 | 写 state |
|---|---|---|---|
| 面板模式 | `htop-s`（默认） | 实时采样 + 渲染，独立计算全部实时指标 | **只读** |
| 后台模式 | `htop-s --daemon`（systemd） | 固定间隔采样、流量累计、告警判定、日志落盘 | **独占写** |

分离带来的好处：

1. 面板不依赖后台服务——服务没装或挂了，`htop-s` 照样能用，只是配额区显示"未启用"
2. 避免两个进程同时写 state 造成数据竞争
3. 面板退出不影响流量统计的连续性

### 3.3 关键数据流

```
面板模式：
  /proc /sys --read--> awk 聚合 --差分--> 缓存 --渲染--> 备用屏缓冲 --> 终端

后台模式：
  /proc /sys --read--> awk 聚合 --差分--> 配额累计 --原子写--> state 文件
                                        └--阈值判定--> 告警日志 (+ NOTIFY_CMD)
                                        └--CSV--> 采集日志（按天）
```

---

## 4. 兼容性设计

### 4.1 bash 3.2 禁用特性清单

实现时**必须避开**以下语法，否则 CentOS 7（bash 4.2）以下或 macOS 派生环境会出问题：

| 禁用 | 替代方案 |
|---|---|
| `declare -A` 关联数组 | 多键聚合全部下推到 awk（awk 原生支持关联数组） |
| `mapfile` / `readarray` | `while IFS= read -r line; do arr+=("$line"); done < <(...)` |
| `${var^^}` / `${var,,}` | `tr '[:lower:]' '[:upper:]'` |
| `&>>` | `>>file 2>&1` |
| `[[ ... ]]` 高级匹配 | 用 `case` 或 `[ ... ]` + `grep -q` |
| `${var//x/y}` 虽可用但慎用 | 简单替换用 `sed`；`${var#pat}` `%pat` 完全安全 |
| `date +%s%N` | 读 `/proc/uptime`，见 §4.2 |
| `local -n` 引用 | 用全局变量或 echo 回传 |
| 数组切片 `${arr[@]:1:2}` | bash 3.2 支持，可安全使用 |

**允许且推荐使用**：普通数组 `()`、`+=` 追加、`local`、`<<<` herestring、进程替换 `< <()`、`${arr[@]}`、算术 `(( ))`、`case`。

### 4.2 单调时钟方案

**禁用** `date +%s%N`（busybox 不支持，返回字面量 `N` 导致算术错误）。

**采用 `/proc/uptime`**：

```bash
# 输出 "秒.百分秒"，如 12345.67
read_uptime() { awk '{print $1}' /proc/uptime; }
```

- 精度：10ms，2 秒采样间隔下误差 < 1%，完全够用
- 稳定性：所有 Linux 内核均支持，busybox / gawk / mawk / busybox-awk 表现一致
- 单调性：不受 NTP 校时影响，天然适合算速率

**差分公式**：

```
dt   = uptime_now - uptime_prev
rate = (counter_now - counter_prev) / dt
```

**必须处理** `dt <= 0`（首次采样、或时间源异常）→ 直接返回 0，不得参与除法。

### 4.3 外部命令能力探测与回退链

启动时执行一次探测，结果缓存到全局变量，运行期不再重复探测。

| 能力 | 首选 | 回退 1 | 回退 2 | 全缺时 |
|---|---|---|---|---|
| 颜色 | `tput` | 硬编码 ANSI 转义 | — | 无色模式 |
| 终端宽度 | `tput cols` | `$COLUMNS` | `stty size` | 80 |
| 页大小 | `getconf PAGESIZE` | — | — | 4096 |
| 每秒时钟节拍 | `getconf CLK_TCK` | — | — | 100 |
| 网卡列表 | `ip -o link` | `/sys/class/net` | `/proc/net/dev` | 报错退出 |
| 进程统计 | `cat /proc/[0-9]*/stat` | 逐 pid 读 | — | 该区显示 N/A |
| 磁盘容量 | `df -P` | `df -kP` | — | 该区显示 N/A |
| 磁盘 inode | `df -Pi` | `df -i` | — | 显示 N/A |
| nftables | `nft` | — | — | 回退 `/proc/net/dev` |
| 温度 | `/sys/class/thermal` | `/sys/class/hwmon` | — | 显示 N/A |
| conntrack | `/proc/sys/net/netfilter/` | — | — | 显示 N/A |

**核心原则：任一数据源缺失只能让对应分区降级显示 `N/A`，绝不允许导致整个脚本报错或退出。**
所有采集函数必须返回可解析的默认值（通常是 0 或空串），调用方必须做空值兜底。

### 4.4 awk 方言兼容

避免 gawk 扩展语法，只使用 POSIX awk 子集。禁用的 gawk 特性：

- `gensub()` → 用 `gsub()` + 中间变量
- `asort()` / `asorti()` → 用 `sort` 外部命令
- `FPAT` / `FIELDWIDTHS` → 用 `split()`
- `match(s, re, arr)` 三参数形式 → 用 `substr` + `index` 手工定位
- `printf` 的 `%b` → 用 `sprintf` 拼接
- `\<` `\>` 词边界 → 用显式分隔符

### 4.5 关键快速通道（性能核心）

**一次性读取全部进程 stat**：

```bash
cat /proc/[0-9]*/stat 2>/dev/null | awk '...'
```

一条命令读完系统全部进程，替代 `ps` 的 fork 开销。实测 500 进程规模下，比 `ps -eo` 快 5~10 倍。

**一次性读取指定网卡计数**：

```bash
awk -v i="eth0" '$1 == i":" {print $2, $10; exit}' /proc/net/dev
```

**注意**：`/proc/net/dev` 的接口名后跟冒号，必须精确匹配 `i":"`，不能用 `~` 模糊匹配，否则 `eth0` 会误匹配 `eth0.100`。

---

## 5. 分帧调度引擎

### 5.1 为什么必须分帧

旧版每帧重算全部指标，单帧需 3 次 `ss -tan` + `df` + `ps`，万级连接时耗时 200ms+。**监控脚本自身成为系统负担**是必须避免的反模式。

### 5.2 帧定义

| 帧 | 周期 | 指标 | 理由 |
|---|---|---|---|
| **快帧** | 2s（可调 1~30） | CPU 总/每核/steal、负载、进程数、内存/Swap/换页、上下行带宽、带宽曲线、TCP·UDP 连接与状态分布 | 秒级波动，必须实时 |
| **中帧** | 10s | 磁盘 IO/IOPS、TOP 进程（实时 CPU）、监听端口→进程、conntrack、重传率、半连接队列溢出 | 变化慢，降频无损感知 |
| **慢帧** | 60s | 磁盘容量/inode、温度、发行版/内核/登录数/僵尸进程、流量配额预估 | 基本不变 |
| **面板重绘** | 同快帧 | 用缓存拼接完整画面 | 保证视觉一致性 |

### 5.3 调度器实现

不使用定时器，用**单调时钟 + 到期判断**（避免 sleep 漂移累积）：

```
每轮循环:
  now = read_uptime
  刷新所有已到期帧（快帧必刷；中/慢帧按 last_run 判断）
  渲染整屏（用缓存）
  读键盘（非阻塞，超时 100ms）
  sleep 剩余时间 = interval - (read_uptime - now)
  若剩余时间 <= 0 则跳过 sleep（说明渲染超时，需触发性能告警）
```

### 5.4 跨帧差分状态

以下指标需要**上一轮采样值**，必须用全局变量跨帧保存：

| 状态变量 | 用途 |
|---|---|
| `PREV_CPU` / `PREV_CPU_N[]` | CPU 总/每核差分 |
| `PREV_RX` / `PREV_TX` | 带宽差分 |
| `PREV_DISK_RD` / `PREV_DISK_WR` / `PREV_DISK_IO` | 磁盘 IO 差分 |
| `PREV_UPTIME` | 差分时间基准 |
| `PREV_PROC_CPU` | 进程 CPU 差分的上一轮快照（pid → utime+stime+starttime） |
| `PREV_TCP_SEG` / `PREV_UDP_ERR` | 协议栈速率差分 |
| `NET_HIST_RX[]` / `NET_HIST_TX[]` | 带宽曲线环形缓冲 |

**进程 CPU 差分的 PID 复用防护（关键）**：

`/proc/[pid]/stat` 的 CPU 时间必须与 `starttime`（第 22 字段）配对校验。若同一 PID 的
`starttime` 发生变化，说明 PID 被复用，必须**丢弃该进程的差分值**并当作首次采样处理，
否则新建进程会显示出一个荒谬的高 CPU 值。

---

## 6. 数据采集规格

### 6.1 汇总表

| 指标 | 数据源 | 计算公式 | 边界处理 |
|---|---|---|---|
| CPU 总量 | `/proc/stat` 首行 | `total = user+nice+system+idle+iowait+irq+softirq+steal` | guest/guest_nice 已含在 user/nice 中，**不得重复累加** |
| CPU 使用率 | 同上 | `busy = 100 - idle% - iowait%` | total 差分 ≤ 0 → 返回 0 |
| CPU 分项 | 同上 | user/sys/io/irq/softirq 各自差分占比 | — |
| CPU steal | 同上 | `steal_delta / total * 100` | VPS 关键指标，物理机恒为 0 |
| 每核 | `/proc/stat` 的 `cpuN` 行 | 同上 | 核数 = `cpuN` 行数，不用 `nproc` |
| 负载 | `/proc/loadavg` | 直接读 `$1 $2 $3` | **第 4 字段是 `运行中/总数`，必须按 `/` 切分**，旧版在此处错位 |
| 进程数 | `/proc/loadavg` 第 4 字段 | `split($4, a, "/")` | — |
| 内存 | `/proc/meminfo` | `已用 = MemTotal - MemAvailable` | 无 MemAvailable（老内核）→ `MemFree+Buffers+Cached` |
| Cached 真实值 | `/proc/meminfo` | `Cached + SReclaimable - Shmem` | 避免把 tmpfs 算进缓存 |
| Dirty/Writeback | `/proc/meminfo` | 直接读 | 持续高位 = IO 写瓶颈 |
| 换页速率 | `/proc/vmstat` | `(pswpin/pswpout 差分) * PAGESIZE / dt` | 单位是**页**，需乘页大小 |
| OOM 次数 | `/proc/vmstat` | `oom_kill` 累计值 | 老内核无此字段 → 显示 N/A |
| 磁盘容量 | `df -P` | 使用率 = `$5` 去 `%` | **必须加 `-P`**，否则长设备名会换行导致字段错乱 |
| 磁盘 inode | `df -Pi` | 同上取 IUse% | 小文件服务器必看 |
| 磁盘 IO | `/proc/diskstats` | `sectors * 512 / dt` | sector 固定 512 字节，与物理扇区无关 |
| IOPS | `/proc/diskstats` | `(reads_completed + writes_completed) 差分 / dt` | — |
| 磁盘利用率 | `/proc/diskstats` | `io_ms 差分 / (dt * 1000) * 100` | 第 13 字段 (ms doing IO) |
| 网卡流量 | `/proc/net/dev` | `$2` / `$10` | 精确匹配 `iface:` 见 §4.5 |
| 网卡错误 | `/proc/net/dev` | `$4` / `$12` | 持续增长 = 物理链路问题 |
| 网卡丢包 | `/proc/net/dev` | `$5` / `$13` | 持续增长 = 带宽或缓冲区打满 |
| TCP 连接 | `/proc/net/tcp` + `tcp6` | 行数 | 见 §8.1 |
| 协议栈 | `/proc/net/snmp` | 见 §8.3 | 必须跳过表头行 |
| 扩展指标 | `/proc/net/netstat` | 见 §8.3 | **必须按表头名匹配列号**，不同内核列序不同 |
| conntrack | `/proc/sys/net/netfilter/nf_conntrack_count` | 占比 = count / max | 文件不存在 → N/A |
| 进程 | `/proc/[pid]/stat` | 见 §9 | comm 含括号，解析要小心 |
| 温度 | `/sys/class/thermal/thermal_zone*/temp` | 值 ÷ 1000 | 毫摄氏度 |

### 6.2 CPU 采集细则

`/proc/stat` 首行字段（`$2` 起）：

| 位置 | 字段 | 说明 |
|---|---|---|
| $2 | user | 用户态 |
| $3 | nice | 低优先级用户态 |
| $4 | system | 内核态 |
| $5 | idle | 空闲 |
| $6 | iowait | IO 等待 |
| $7 | irq | 硬中断 |
| $8 | softirq | 软中断 |
| $9 | steal | 被宿主机抢占（VPS 关键） |
| $10 | guest | **已含在 user 中，不重复加** |
| $11 | guest_nice | **已含在 nice 中，不重复加** |

总量口径与 `top` 保持一致：`100 = us + sy + ni + id + wa + hi + si + st`，因此
**使用率（忙）= 100 − idle% − iowait%**。

### 6.3 内存采集细则

`MemAvailable` 是内核给出的"还够用多少"，`已用 = MemTotal − MemAvailable` 才是
现代 Linux 的正确"已用"口径（`free` 命令同此）。旧版 `htop-s` 采用此口径，保留。

### 6.4 磁盘设备过滤

`df` 输出需过滤掉非物理设备，但**不能只看第一列字符串**（LVM/加密设备名多样）。推荐策略：

1. 按文件系统类型过滤：`tmpfs` `devtmpfs` `squashfs` `overlay` `ramfs` `proc` `sysfs` `cgroup` `cgroup2` `fuse.*` `nfs*` `autofs`
2. 保留 `ext*` `xfs` `btrfs` `zfs` `f2fs` `jfs` `reiserfs` 及未知类型
3. 按使用率降序，取前 3 行显示

`/proc/diskstats` 则相反——**只统计整盘，排除分区**。判断方法：`/sys/block/<name>` 目录
存在则为整盘。需排除 `loop*` `ram*` `zram*`，但**保留** `dm-*`（LVM）、`md*`（软 RAID）、
`nvme*n*`（整盘）、`sd*` `vd*` `xvd*`。

---

## 7. 流量计量与配额（核心模块）

### 7.1 双模式设计

| 模式 | 数据源 | 跨服务器重启 | 前置条件 |
|---|---|---|---|
| **增强模式** | nftables 计数器 | **不丢** | 有 `nft` 命令 + root |
| **基础模式** | `/proc/net/dev` | 重启期间丢失，标注"数据不完整" | 无 |

启动时自动探测：`command -v nft && [ -w /proc/sys/net/netfilter ] 2>/dev/null || id -u = 0`。
探测失败静默回退，面板对应位置显示数据完整性标记。

### 7.2 nftables 增强方案

#### 7.2.1 硬约束（不可违反）

1. **只新建独立 table `inet htop_s`，绝不修改用户已有 table**
2. 自建链的 `policy` 必须为 `accept`，且**只含 counter 规则，不含任何 verdict 语句**
3. 不用 `flush ruleset`、不动 `iptables-*` 兼容表、不动 `nf_tables` 其他 table
4. 卸载时必须完整清理自建 table，恢复系统到安装前状态

#### 7.2.2 表结构

计数必须挂在数据包必经路径上，且 chain 必须带 hook 才会执行（**这是常见误区：无 hook 的 chain 中的规则永远不会被计数**）。

```nft
table inet htop_s {
    chain in_acct {
        type filter hook prerouting priority 0; policy accept;
        iifname "eth0" counter
    }
    chain out_acct {
        type filter hook postrouting priority 0; policy accept;
        oifname "eth0" counter
    }
}
```

- `prerouting` 覆盖**所有入站**（无论最终走向 input 还是 forward，含 Docker/NAT 场景）
- `postrouting` 覆盖**所有出站**（本地产生与转发均经过）
- `priority 0` 为 filter 默认优先级，与其他表的 filter 链并存不冲突
- 多网卡时每个网卡一条 counter 规则，用 comment 标识便于解析

#### 7.2.3 计数读取

```bash
nft list table inet htop_s
```

输出中 `counter packets N bytes M`，按行解析 `bytes` 值。需按 chain 名区分入站/出站。

**注意**：`nft -j` 的 JSON 输出需要 `jq`，违反零依赖原则，故使用文本输出配合 awk 解析。

#### 7.2.4 规则生命周期

| 时机 | 动作 |
|---|---|
| `--install` | 创建 table 与 ruleset |
| 开机（systemd） | `ExecStartPost` 调用 `--ensure-acct` 幂等重建 |
| `--upgrade` | 重建（覆盖旧版本规则） |
| 网卡变更 | 检测到配置的网卡不在 ruleset 中 → 自动补建 |
| `--acct off` | 删除自建 table，切回基础模式 |
| `--uninstall` | 删除自建 table |

服务单元需 `After=network-pre.target`，让计数尽早开始，减少开机窗口期的流量丢失（该窗口期流量无法补回，属已知限制）。

### 7.3 状态文件

#### 7.3.1 路径

| 身份 | 路径 |
|---|---|
| root | `/var/lib/htop-s/state` |
| 普通用户 | `${XDG_STATE_HOME:-$HOME/.local/state}/htop-s/state` |

#### 7.3.2 格式

纯文本 `key=value`，每行一条，便于 awk 解析和人工排查：

```
version=1
mode=nft                        # nft | proc
period_start=2026-09-01
period_reset_day=1              # 1~28，账单日
quota_bytes=1099511627776       # 月配额，0=不限
iface_list=eth0

# nft 模式：本期已归档量（历次重启前累积）+ 当前计数器读数
nft_rx_done=0
nft_tx_done=0
nft_rx_last=0
nft_tx_last=0

# proc 模式：基准值与最新读数
proc_rx_base=0
proc_tx_base=0
proc_rx_last=0
proc_tx_last=0

# 重启判定
uptime_last=12345.67
ts_last=1758000000

# 告警状态机
alert_cpu_state=ok
alert_cpu_last=0
alert_mem_state=ok
...
```

#### 7.3.3 原子写入

**必须**采用「临时文件 + rename」模式，避免断电/中断写入损坏文件：

```bash
tmp="$STATE_FILE.tmp.$$"
write_state_to "$tmp"
mv -f "$tmp" "$STATE_FILE"     # rename 在 POSIX 文件系统上是原子的
```

`mv` 必须同文件系统内（临时文件放同目录，不放 `/tmp`）。

### 7.4 流量累计算法

#### 7.4.1 nft 模式（跨重启不丢）

```
每轮采样:
  (nft_rx_now, nft_tx_now) = 读 nft 计数器

  if 检测到服务器重启 (uptime_now < uptime_last - 5):
      # nft 表被重建，计数器归零，先把上次读数归档
      nft_rx_done += nft_rx_last
      nft_tx_done += nft_tx_last
      nft_rx_now = 0
      nft_tx_now = 0

  period_rx = nft_rx_done + nft_rx_now
  period_tx = nft_tx_done + nft_tx_now

  if 周期已滚动:
      归档本周期到 history 文件
      nft_rx_done = nft_rx_now
      nft_tx_done = nft_tx_now
      重置 period_start

  原子写 state
```

**只需保证每次采样都落盘**，两次落盘间隔内的重启最多丢失一个采样周期（默认 5 秒）的流量，可接受。

#### 7.4.2 proc 模式（重启期间丢失）

```
period_rx = proc_rx_last - proc_rx_base

若检测到重启:
    # 计数器归零，历史无从追溯
    incomplete = 1                  # 面板显示"数据不完整"
    proc_rx_base = 0                # 基准归零，当前读数即为重启后新量
    # 注：重启前的增量已在上一轮采样计入过，不重复累加
```

**重要区分**：daemon 进程重启（服务器未重启）时，`/proc/net/dev` 计数器仍在，
直接续算，**不丢数据**。只有服务器重启才会丢。用户须知中必须写清这一点。

### 7.5 周期滚动

| 配置 | 行为 |
|---|---|
| `--reset-day 1`（默认） | 每自然月 1 日 00:00 滚动 |
| `--reset-day N`（1~28） | 每自然月第 N 日滚动（避开月末，避免 2 月问题） |

判断逻辑（用字符串比较即可，无需算天数）：

```
today = $(date +%Y-%m-%d)
若今天 >= 本期开始日 + 1 个周期  → 滚动
用 date -d（GNU）计算下个周期起点；busybox date 不支持 -d → 用纯算术：
  取出年月日，月份+1，处理跨年，日固定为 reset_day
```

**禁止依赖 `date -d`**（busybox 不支持）。周期计算必须用 shell 算术完成。

### 7.6 用量预估

```
已用天数   = 今天 - period_start + 小数部分
日均用量   = period_used / 已用天数
预测月末   = 日均用量 * 周期总天数
超限风险   = 预测月末 > quota_bytes
```

周期总天数：按当月实际天数计算（28~31）。已用天数 < 0.5 天时不显示预测（样本不足，会给出荒谬值）。

---

## 8. 连接与协议栈

### 8.1 `/proc/net/tcp` 解析

**格式**：

```
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000   102        0 12345 1 0000:000000 100 0 0 10 0
```

**字段定位（awk）**：`$1`=sl `$2`=local `$3`=rem `$4`=st `$5`=tx:rx `$6`=tr:tm `$7`=retrnsmt `$8`=uid `$9`=timeout `$10`=inode

**注意**：最后几个字段是内核新增的，**必须用固定列号取 inode（第 10 列）**，不要按倒数字段取。

### 8.2 地址与端口解码

| 项 | 编码 | 解码方法 |
|---|---|---|
| IPv4 地址 | 小端序十六进制，`0100007F` | 每 2 字符拆开，逆序拼接，转十进制 |
| IPv6 地址 | 4 组 32 位小端序，`00000000000000000000000001000000` | 实现复杂，**只统计数量，不解析显示** |
| 端口 | 大端序十六进制，`0035` | 直接十六进制转十进制 |

IPv4 解码在 awk 中用 `strtonum` 属 gawk 扩展，**POSIX 兼容写法**：

```awk
function hex2dec(h,   i, c, v, r, s) {
    s = "0123456789ABCDEF"
    r = 0
    h = toupper(h)
    for (i = 1; i <= length(h); i++) {
        c = index(s, substr(h, i, 1)) - 1
        if (c < 0) return -1
        r = r * 16 + c
    }
    return r
}
```

### 8.3 TCP 状态码映射

| 码 | 状态 | 面板配色 | 含义 |
|---|---|---|---|
| 01 | ESTABLISHED | 绿 | 正常连接 |
| 02 | SYN_SENT | 灰 | 本机发起的握手 |
| 03 | SYN_RECV | **红** | 半连接堆积，疑似 SYN Flood / 端口扫描 |
| 04 | FIN_WAIT1 | 灰 | 主动关闭中 |
| 05 | FIN_WAIT2 | 灰 | 等待对方 FIN |
| 06 | TIME_WAIT | **黄** | 正常回收期；≥ 30000 需关注 |
| 07 | CLOSE | 灰 | 短暂状态 |
| 08 | CLOSE_WAIT | **红** | **应用未关闭连接，通常是程序 bug** |
| 09 | LAST_ACK | 灰 | 被动关闭收尾 |
| 0A | LISTEN | 青 | 监听中 |
| 0B | CLOSING | 灰 | 双方同时关闭 |
| 0C | NEW_SYN_RECV | 黄 | 新内核状态 |

### 8.4 协议栈指标

**`/proc/net/snmp`**：成对出现，**奇数行是表头，偶数行是值**，必须校验行号奇偶或比对字段名。

```
Tcp: RtoAlgorithm RtoMin ... InSegs OutSegs RetransSegs InErrs OutRsts ...
Tcp: 1 200 ... 123456 234567 890 0 12 ...
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors ...
Udp: 98765 12 0 98700 0 0 ...
```

| 指标 | 计算 |
|---|---|
| TCP 重传率 | `RetransSegs 差分 / OutSegs 差分 * 100` |
| TCP 入错包 | `InErrs 差分` |
| UDP 收包错误 | `InErrors 差分` |
| UDP 缓冲溢出 | `RcvbufErrors 差分` |

**`/proc/net/netstat`**：同样是表头/值成对，但**列顺序在不同内核版本间不一致**，
必须**动态按表头名查找列号**，绝不能硬编码列位置。需要提取：

| 字段 | 含义 |
|---|---|
| `ListenOverflows` | accept 队列溢出（应用来不及 accept） |
| `ListenDrops` | 监听队列丢弃（SYN 被丢） |
| `TCPSynRetrans` | SYN 重传（网络质量） |
| `TCPTimeWaitOverflow` | TIME_WAIT 超上限 |
| `SyncookiesSent` | 触发 SYN Cookie（半连接攻击迹象） |

实现方式：先读表头行 `TcpExt: ...`，建立 `列名 → 列号` 映射，再读值行按映射取值。

### 8.5 监听端口 → 进程映射

**按需触发**（按 `p` 键），不在每帧执行——该操作需遍历 `/proc/*/fd/`，开销较大。

算法：

1. 读 `/proc/net/tcp`，筛出 `st == 0A`（LISTEN），得到 `(地址:端口 → socket inode)` 映射
2. 遍历 `/proc/[0-9]*/fd/*`，`readlink` 得到 `socket:[<inode>]`，建立 `inode → pid` 反查
3. 关联步骤 1、2，得到 `端口 → pid → 进程名`
4. 同一端口多个进程（`SO_REUSEPORT`）时列出全部

**权限**：非 root 只能看到自己进程的 fd，其他显示为 `?`。文档需注明。

**性能优化**：只对 LISTEN 状态的 inode 建反查表（通常 < 100 个），而不是全量扫描。

---

## 9. 进程视图

### 9.1 实时 CPU（差值法）

旧版用 `ps -eo pcpu`，该值是**进程整个生命周期的平均值**，不是瞬时值，高负载时严重失真。必须改为差值法：

```
CPU% = (Δutime + Δstime) / CLK_TCK / Δt * 100
```

- `utime` = `/proc/[pid]/stat` 第 14 字段，`stime` = 第 15 字段
- `CLK_TCK` 从 `getconf CLK_TCK` 获取，回退 100
- `Δt` 来自 `/proc/uptime` 差分

### 9.2 comm 字段解析陷阱

`/proc/[pid]/stat` 第 2 字段 `comm` 是**带括号的进程名**，进程名中可能包含空格和括号
（如 `(sd-pam)`、`(node) foo`）。**不能按空格 split**，必须：

```awk
# 定位最后一个 ')'，其后的部分按空格切开
{
    p = 0
    for (i = length($0); i > 0; i--) {
        if (substr($0, i, 1) == ")") { p = i; break }
    }
    comm = substr($0, 2, p - 2)
    rest = substr($0, p + 2)
    n = split(rest, f, " ")
    # 之后 f[1]=state f[2]=ppid ... f[12]=utime f[13]=stime ...
}
```

**字段偏移换算**：`stat` 原文第 14 字段（utime）在剥离前 2 字段后，位于 `f` 数组的第 12 位；`starttime`（第 22）位于第 20 位；`num_threads`（第 20）位于第 18 位；`vsize`（第 23）位于第 21 位；`rss`（第 24）位于第 22 位。实现时必须以注释形式写明换算，避免后续维护出错。

### 9.3 进程展示字段

| 字段 | 来源 |
|---|---|
| PID | stat[1] |
| CPU% | 差值法 |
| MEM% | `rss * PAGESIZE / MemTotal * 100` |
| 线程数 | stat 第 20 字段 |
| 状态 | stat 第 3 字段，`R/S/D/Z/T/I` |
| 命令行 | `/proc/[pid]/cmdline`（`\0` 分隔，替换为空格） |

**D 状态高亮**：`D` = 不可中断睡眠，通常意味 IO 阻塞或 NFS 挂死，**必须红色高亮**并在
面板顶部给出提示。这是排查"服务器卡死"最有效的信号。

**cmdline 优化**：优先读 `cmdline`（完整命令行），失败或为空（内核线程）时回退到 `comm`。
截断到终端宽度的 1/3，超出用 `…` 省略。

### 9.4 排序模式

| 键 | 模式 | 排序依据 |
|---|---|---|
| `c` | CPU（默认） | CPU% 降序 |
| `m` | 内存 | MEM% 降序 |
| `n` | 网络 | 连接数降序（需 `p` 模式已激活） |
| `i` | IO | read_bytes + write_bytes 差分（需 root） |

---

## 10. 终端界面规格

### 10.1 分区布局（从上到下）

| # | 分区 | 帧 | 内容 |
|---|---|---|---|
| 1 | 标题栏 | — | 标题 + 当前排序模式 + 键位提示 |
| 2 | 主机信息 | 慢 | 主机名、时间、uptime、核数、发行版/内核/架构 |
| 3 | 系统概况 | 慢 | IP、登录用户数、僵尸进程、负载（含 ÷核数 归一值） |
| 4 | CPU | 快 | 总占用量条 + user/sys/io/steal 分项 |
| 5 | 每核视图 | 快 | `1` 键展开，每核一个短条 |
| 6 | 内存 | 快 | 量条 + 已用/总量 + Cached + Swap + 换页速率 |
| 7 | 磁盘容量 | 慢 | 使用率 TOP3 + inode |
| 8 | 磁盘 IO | 中 | 读写速率 + IOPS + 利用率 |
| 9 | 网络 | 快 | 网卡、IP、累计、实时上下行、峰值、错误丢包 |
| 10 | 流量配额 | 慢 | 本月用量/配额/百分比/预估/数据完整性标记 |
| 11 | 带宽曲线 | 快 | 上下行双行 sparkline |
| 12 | TCP/UDP | 快+中 | 连接数、状态分布（分色）、协议栈指标、UDP 错误；`p` 展开端口映射 |
| 13 | 进程 | 中 | TOP 进程表（PID/CPU%/MEM%/线程/状态/命令） |
| 14 | 底栏 | — | 退出提示 + 告警摘要 + 渲染耗时 |

### 10.2 曲线渲染

用 Unicode 块字符 `▁▂▃▄▅▆▇█`（8 级）绘制，宽度 = 终端宽度 − 12。

- 环形缓冲保留最近 N 个采样点（N = 可用宽度）
- 归一化基准取缓冲内最大值，且设下限（如 64KB/s），避免低流量时噪声被放大成满格
- ASCII 模式下退化为 `.` `:` `-` `=` `+` `*` `#` `@`

### 10.3 颜色阈值

| 使用率 | 颜色 |
|---|---|
| < 60% | 绿 |
| 60 ~ 85% | 黄 |
| ≥ 85% | 红 |

TCP 状态、D 状态进程按 §8.3 / §9.3 单独配色，不套用此表。

### 10.4 备用屏缓冲（消除闪屏）

**必须使用**，这是与旧版体验差异最大的改动之一：

```
进入: printf '\033[?1049h'    # 切到备用屏
      printf '\033[?25l'      # 隐藏光标
      printf '\033[H'         # 光标归位
每帧: printf '\033[H'         # 仅归位，不清屏；每行用 \033[K 清到行尾
退出: printf '\033[?25h\033[0m\033[?1049l'   # 恢复光标 + 复位属性 + 回主屏
```

**旧版用 `\033[2J` 全屏清屏**（L451）→ SSH 下闪屏、滚动条跳动、退出后终端历史被清空。
备用屏方案退出后终端内容完整恢复，体验接近 htop 本身。

**异常退出保护**：`trap` 必须捕获 `EXIT` `INT` `TERM` `HUP`，确保无论何种方式退出
都能恢复屏幕与终端属性（`stty`）。同时设 `sane` 兜底：退出前 `stty sane`。

### 10.5 宽度自适应

- 启动时探测宽度，运行中监听 `SIGWINCH` 重绘
- 所有分隔线、量条、曲线按实际宽度计算，**不得硬编码 60 列**（旧版 L375 问题）
- 宽度 < 60 时进入紧凑模式：隐藏每核视图、端口映射、磁盘 IO 三个次要分区
- 宽度 < 40 时提示"终端过窄，请调整窗口"

### 10.6 键盘输入

bash 3.2 环境下读单个按键的可靠做法：

```bash
# 启动时一次性设置，不每次循环设置
stty -icanon -echo min 1 time 0 2>/dev/null
# 读取（阻塞式，配合后台超时）
key=$(dd bs=1 count=1 2>/dev/null)
```

顶部再套一层超时控制：用 `read -t` 不支持小数秒（bash 3.2 的 `-t` 只接受整数），
故采用「`stty time 1` + `dd`」实现 100ms 超时轮询。

**必须处理 `stty` 不可用的情况**（重定向输入时）→ 跳过键盘读取，退化为纯刷新显示。

### 10.7 键位表

| 键 | 功能 |
|---|---|
| `q` / `Q` / `Ctrl-C` | 退出并恢复终端 |
| 空格 | 暂停 / 继续刷新（暂停时仍可切视图） |
| `r` | 立即刷新一次 |
| `c` / `m` / `n` / `i` | TOP 进程排序：CPU / 内存 / 网络 / IO |
| `1` | 展开 / 收起每核视图 |
| `p` | 展开 / 收起监听端口 → 进程映射 |
| `+` / `-` | 刷新间隔 ±1 秒（范围 1~30） |
| `s` | 当前快照追加写入日志 |
| `?` / `h` | 帮助浮层（再按任意键返回） |

---

## 11. 后台服务与 systemd

### 11.1 服务单元

`/etc/systemd/system/htop-s.service`：

```ini
[Unit]
Description=htop-s server monitor daemon
Documentation=man:htop-s(1)
After=network-pre.target local-fs.target
Wants=network-pre.target
ConditionPathExists=/usr/local/bin/htop-s

[Service]
Type=simple
ExecStart=/usr/local/bin/htop-s --daemon
ExecStartPost=/usr/local/bin/htop-s --ensure-acct
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=3
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
MemoryMax=64M
CPUQuota=10%
LimitNOFILE=4096
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**资源限制是刻意加的**——监控进程绝不能成为系统负担。`CPUQuota=10%` 保证它最多占用
1/10 核，`MemoryMax=64M` 防止内存泄漏拖垮机器。

`After=network-pre.target` 让流量计数尽早启动，缩小开机窗口期的丢量。
不用 `DefaultDependencies=no` + `Before=sysinit.target`，那会与基本系统服务产生复杂依赖。

### 11.2 单实例保护

`--daemon` 启动时检查 PID 文件：

```
若 PID 文件存在且进程存活 → 打印"已在运行 (pid N)"并退出 1
若 PID 文件存在但进程已死 → 清理残留后继续
```

PID 文件路径：root `/var/run/htop-s.pid`，普通用户 `${XDG_RUNTIME_DIR:-/tmp}/htop-s-$UID.pid`。

**同时用 `flock` 兜底**（若可用），避免 PID 文件竞态：

```bash
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "已在运行"; exit 1; }
```

`flock` 缺失时静默跳过，仅依赖 PID 文件。

### 11.3 日志管理

| 项 | 设计 |
|---|---|
| 路径 | root `/var/log/htop-s/`，普通用户 `~/.local/share/htop-s/log/` |
| 切分 | **按天**，文件名 `collect-YYYY-MM-DD.csv` |
| 格式 | CSV，17 列：`时间,epoch,uptime,cpu%,mem%,swap%,load1,down_bps,up_bps,tcp,udp,disk_rd,disk_wr,rx_err,tx_err,rx_bytes,tx_bytes` |
| 尾两列 | `rx_bytes` / `tx_bytes` 是**本周期的增量字节数**（不是速率）。有了它，`--today` / `--month` 直接求和即可得到精确流量，不必对速率做积分近似 |
| 告警判定 | 与采样同频（默认 5 秒），因此"连续 3 次"= 15 秒，与告警示例中的"已持续 15 秒"一致 |
| 压缩 | 非当日文件用 `gzip` 压缩（若可用），得到 `.csv.gz` |
| 保留 | 默认 30 天，可配 `--keep N` |
| 清理 | **每轮循环检查**（旧版仅在启动时检查一次，长跑进程永不轮转） |

**关键修复**：旧版把轮转逻辑写在 `daemon_loop` 开头（L577），进程一旦启动就再也不会执行
轮转判断，导致日志无限增长。新版必须把「跨天切分 + 清理超期」放进**每轮循环内**，
并用「当前日期字符串 ≠ 上次记录的日期」作为触发条件（每天只执行一次，开销可忽略）。

告警日志单独文件：`alert-YYYY-MM-DD.log`，纯文本便于 `grep`。

### 11.4 组件的启动与停止关系

| 操作 | 面板 | 后台服务 | nft 计数 |
|---|---|---|---|
| `htop-s` | 启动 | 不受影响 | 只读 |
| `htop-s --install` | — | 安装并启动 | 创建 |
| `htop-s --stop` | — | 停止 | 保留（避免流量丢失） |
| `htop-s --uninstall` | — | 停止并移除 | 删除 |
| 系统重启 | — | 自动启动 | 由 `ExecStartPost` 重建 |

---

## 12. 告警引擎

### 12.1 规则表

| ID | 指标 | 阈值 | 触发条件 | 级别 |
|---|---|---|---|---|
| `cpu` | CPU 使用率 | ≥ 90% | 连续 3 次 | warn |
| `mem` | 内存使用率 | ≥ 90% | 连续 3 次 | warn |
| `swap` | Swap 使用率 | ≥ 50% | 连续 3 次且换页 > 0 | warn |
| `disk` | 磁盘使用率 | ≥ 90% | 单次 | crit |
| `inode` | inode 使用率 | ≥ 90% | 单次 | crit |
| `load` | 负载/核数 | ≥ 2.0 | 连续 3 次 | warn |
| `conntrack` | conntrack 占用 | ≥ 80% | 单次 | crit |
| `syn` | SYN_RECV | ≥ 100 | 单次 | crit |
| `timewait` | TIME_WAIT | ≥ 30000 | 单次 | warn |
| `closewait` | CLOSE_WAIT | ≥ 500 | 连续 3 次 | warn |
| `listen_drop` | ListenOverflows 增量 | > 0 | 连续 3 次 | warn |
| `retrans` | TCP 重传率 | ≥ 5% | 连续 3 次 | warn |
| `nic_err` | 网卡错误/丢包增量 | > 0 | 连续 3 次 | warn |
| `quota` | 月流量 | ≥ 配额 80% | 单次（跨档时触发） | warn |
| `quota` | 月流量 | ≥ 配额 100% | 单次 | crit |
| `dstate` | D 状态进程 | 存在 | 连续 5 次 | crit |
| `netdown` | 断网 | ping 网关失败 | 连续 3 次 | crit |
| `oom` | OOM 事件 | 增量 > 0 | 单次 | crit |

### 12.2 状态机

每个规则独立维护：`ok` → `pending`（计数中）→ `firing`（已触发）→ `cooldown` → `ok`

```
采样时判定:
  if 条件成立:
      pending_count++
      if pending_count >= 连续次数阈值 and state == ok:
          state = firing; 推送告警; last_push = now
  else:
      if state == firing:
          推送"已恢复"; state = ok
      pending_count = 0

冷却: if now - last_push < 600 and state == firing: 不重复推送
```

状态与计数**必须持久化到 state 文件**——否则服务重启会导致连续计数归零，长期缓慢恶化的
问题（如内存缓慢上涨）永远触发不了告警。

### 12.3 告警输出

**本地日志**（默认且唯一通道）：

```
2026-09-17 09:12:33 [CRIT] [syn] SYN_RECV=142 (阈值 100) 疑似 SYN Flood，当前连接 TOP 来源: 203.0.113.7 (86)
2026-09-17 09:15:02 [WARN] [cpu] CPU=92.3% 已持续 15 秒，TOP 进程: 8821 node (38.1%)
```

格式要素：时间、级别、规则 ID、实际值、阈值、可读的诊断上下文。

**扩展钩子**：若配置了 `NOTIFY_CMD`（环境变量或配置项），每条告警额外执行：

```bash
printf '%s' "$ALERT_TEXT" | eval "$NOTIFY_CMD"
```

这样用户想接企业微信/钉钉，只需填一条 `curl` 命令，代码零改动。
`--test-alert` 用于验证钩子连通性。

---

## 13. 命令接口规格

### 13.1 完整命令表

#### 运行与显示

| 命令 | 说明 |
|---|---|
| `htop-s` | 进入实时面板（默认，2 秒刷新） |
| `htop-s -i N` | 刷新间隔 N 秒（1~30） |
| `htop-s -I eth0[,eth1]` | 指定网卡，支持多网卡逗号分隔求和 |
| `htop-s -e` | 英文界面 |
| `htop-s -a` | ASCII 字符模式（终端不支持 UTF-8 时） |
| `htop-s -n` | 单次快照输出到 stdout 后退出（排障/管道/脚本调用） |
| `htop-s -m` | 精简模式：只显示流量与连接（窄终端/低带宽场景） |
| `htop-s -p` | 显示「端口 → 进程」映射并直接退出采集（使该路径可被非交互测试覆盖） |

#### 部署与生命周期

| 命令 | 说明 |
|---|---|
| `htop-s --install` | 一键安装：复制到 `/usr/local/bin`、装 systemd 服务、开机自启、初始化 state、启用 nft 计数 |
| `htop-s --uninstall` | 卸载服务与脚本（**保留** state 与日志） |
| `htop-s --uninstall --purge` | 完全清理，含 state、日志、nft 表 |
| `htop-s --upgrade` | 用当前文件覆盖已安装版本，重建服务与 nft 规则 |
| `htop-s --daemon` | 前台运行后台采集（systemd 调用，一般不由用户直接执行） |
| `htop-s --start` | 启动后台服务 |
| `htop-s --stop` | 停止后台服务（**保留 nft 计数**，避免流量统计断点） |
| `htop-s --restart` | 重启后台服务 |
| `htop-s --status` | 一览：服务状态、自启状态、采集进程、日志大小、配额用量、nft 状态 |

#### 数据查询

| 命令 | 说明 |
|---|---|
| `htop-s --log [N]` | 查看采集日志，默认 30 行（**修复旧版 `--log 100` 失效问题**） |
| `htop-s --alert [N]` | 查看告警日志，默认 30 行 |
| `htop-s --today` | 今日汇总：总流量、峰值带宽、平均/峰值负载、告警次数、TOP 告警规则 |
| `htop-s --month` | 本月汇总：同上 + 配额使用率 + 日均用量 + 月末预测 |
| `htop-s --export` | 当前快照导出为 CSV 到 stdout |
| `htop-s --history [N]` | 最近 N 个周期的流量归档记录 |

#### 配置

| 命令 | 说明 |
|---|---|
| `htop-s --quota 1024G` | 设置月流量配额（支持 `K/M/G/T` 后缀，`0` = 不限） |
| `htop-s --reset-day 1` | 设置计量周期起始日（1~28） |
| `htop-s --keep 30` | 日志保留天数 |
| `htop-s --iface eth0` | 持久化默认网卡（写入配置文件） |
| `htop-s --config` | 显示当前生效配置及来源 |
| `htop-s --acct on\|off\|status` | nftables 计数开关与状态 |
| `htop-s --ensure-acct` | 幂等重建 nft 规则（开机/升级后调用） |

#### 诊断

| 命令 | 说明 |
|---|---|
| `htop-s --check` | 环境自检：逐项探测数据源、命令、权限，输出兼容性报告 |
| `htop-s --test-alert` | 触发一条测试告警，验证日志写入与 `NOTIFY_CMD` |
| `htop-s --selftest` | 内置自测：语法、各采集函数、边界条件，返回通过/失败统计 |
| `htop-s -V` / `--version` | 版本号 |
| `htop-s -h` / `--help` | 帮助 |

### 13.2 `--check` 输出设计

```
htop-s 环境自检 v2.0
─────────────────────────────────────────────
系统        Linux 6.1.0-13-amd64 x86_64
发行版      Debian GNU/Linux 12 (bookworm)
bash        5.2.15                      OK   (需要 >= 3.2)
awk         mawk 1.3.4                  OK
时钟源      /proc/uptime 12345.67       OK   (精度 10ms)
页大小      4096                        OK
CLK_TCK     100                         OK
CPU 核数    8                           OK
进程采集    /proc/[pid]/stat            OK   (512 个进程)
磁盘容量    df -P                       OK   (3 个可用挂载点)
磁盘 IO     /proc/diskstats             OK   (2 个整盘)
网卡        eth0 (10.0.0.21)            OK
TCP 采集    /proc/net/tcp               OK   (218 连接)
协议栈      /proc/net/netstat            OK   (表头匹配成功)
conntrack   312 / 65536                 OK
温度        N/A                         跳过  (无热区，虚拟机常见)
nftables    nft 1.0.6                   OK   (root 权限可用)
流量模式    增强模式 (nftables)
systemd     systemd 252                 OK
─────────────────────────────────────────────
结论: 全部功能可用
```

非 OK 项用醒目颜色标注，并在末尾给出针对性建议。

### 13.3 参数解析重构

旧版解析器有两个缺陷必须修掉：

1. **`--log N` 失效**（L725）：主解析循环用 `shift` 消费参数后，`$1` 已为空，
   后续 `do_log "${1:-30}"` 永远拿不到 N。
   **解决**：用 `while [ $# -gt 0 ]` + `case` 时，对需要值的选项**当场消费**，
   并把值存入全局变量（如 `OPT_LOG_LINES`），不再依赖 `$1`。

2. **未知参数提示不友好**：当前直接打印 usage 后 `exit 0`（错误退出码）。
   **解决**：未知参数打印到 stderr，显示"未知参数: xxx"和"用 htop-s -h 查看帮助"，
   **退出码 1**。

同时补充：

- 数值型参数校验（`-i` 必须 1~30 整数，`--quota` 必须合法容量格式）
- 长选项支持 `--opt=value` 写法
- 冲突检测（如同时给 `--install` 和 `--uninstall` 应报错）

---

## 14. 部署方案

### 14.1 三种形态对比

| 方案 | 部署方式 | 依赖 | 体积 | 建议 |
|---|---|---|---|---|
| **A. 单文件裸部署**（推荐） | `scp` + `chmod +x` | 目标机有 bash 3.2+ + awk | ~80KB | **主方案** |
| **B. 系统级安装** | `htop-s --install` | 同 A + root + systemd | 同 A | 需要开机自启时用 |
| **C. 编译为真二进制** | `shc` 或 Go 重写 | 无（静态链接） | 1~5MB | 按需，见下 |

### 14.2 方案 A：单文件裸部署（主方案）

```bash
# 本机
scp htop-s root@server:/usr/local/bin/htop-s

# 服务器
ssh root@server
chmod +x /usr/local/bin/htop-s
htop-s
```

**这一形态已达成"二进制级"的部署体验**：单个文件、无安装步骤、无包管理、无运行库依赖、
拷过去就能跑。对于纯查看需求（不需要开机自启），到此即可，**不需要 root**。

这正是选择「纯 bash + awk 零依赖」的技术回报——如果把数据源换成 `vnstat`/`sysstat`，
部署就不再是"拷一个文件"，而是"先装三个包"。

### 14.3 方案 B：系统级安装

```bash
sudo htop-s --install
```

一条命令完成六件事：

1. 复制脚本到 `/usr/local/bin/htop-s`
2. 写入 `/etc/systemd/system/htop-s.service`
3. `systemctl enable --now htop-s.service`（开机自启 + 立即启动）
4. 初始化 state 文件与日志目录
5. 若可用，创建 nftables 计数表
6. 创建配置目录 `/etc/htop-s/`

安装后：

- 开机自动在后台采集，无需任何人工干预
- SSH 登录后敲 `htop-s` 即可查看实时面板
- `htop-s --status` 可查看整体健康状况

可选增强：安装一个 `/etc/profile.d/htop-s.sh`，SSH 登录时提示
「输入 htop-s 查看服务器实时监控」。默认**不安装**，需 `--install --with-motd` 显式开启，
避免污染用户登录环境。

### 14.4 方案 C：编译为真二进制（可选）

仅当以下需求出现时才考虑：目标机完全没有 bash（极少见）、需要隐藏源码、
需要通过堡垒机分发单一可执行文件。

#### C1. `shc` 封装（低成本）

```bash
shc -f htop-s -o htop-s.bin
```

原理：把脚本加密后嵌入 C 代码，编译为 ELF，运行时解密并调用系统 bash 执行。

| 优点 | 缺点 |
|---|---|
| 改动最小，一天完成 | **仍依赖目标机的 bash**，且依赖 `sh`、`awk` |
| 部署成单 ELF 文件 | 加密可被轻易还原（`SHC` 有公开解密工具） |
| | 部分杀软会误报（自解压 + exec 特征） |

**结论：收益有限，仅作过渡。** 若目标机本来就有 bash，方案 A 更简单可靠。

#### C2. Go 重写（高成本，真静态二进制）

| 优点 | 缺点 |
|---|---|
| 真静态链接，`CGO_ENABLED=0` 后可在任意 Linux 上跑 | **完全重写，工作量是 bash 版的 2~3 倍** |
| 原生并发，性能余量大 | 二进制 2~5MB，需交叉编译维护多架构 |
| 无需任何外部命令（不依赖 awk） | 失去了 bash 版「可现场改一行就生效」的灵活性 |

**结论：除非出现"目标机不能装 bash"的硬需求，否则不启动。** 本文档的架构设计
（采集函数 → 聚合 → 缓存 → 渲染 四层分离）本身就是为 Go 重写预留的——
采集层接口清晰，重写时只需替换 L1/L2，L3/L4 逻辑可平移。

### 14.5 升级与回滚

```bash
# 升级：用本地新版覆盖服务器上已安装的版本
scp htop-s.new root@server:/tmp/htop-s && ssh root@server /tmp/htop-s --upgrade

# 回滚：升级前自动备份
# /usr/local/bin/htop-s.bak 会在 --upgrade 时自动生成
```

`--upgrade` 的要求：先做 `bash -n` 语法检查，**语法不过就不覆盖**，避免把服务器搞坏。

---

## 15. 测试与验收

### 15.1 旧版缺陷回归清单（13 项，逐条验证）

| # | 缺陷 | 验收方法 |
|---|---|---|
| 1 | `${T_CPU}`/`${C_CPU_COL}`/`${TITLE_EXTRA}` 未定义 + `set -u` 崩 | `bash -u htop-s` 无 unbound 报错 |
| 2 | L453/L458/L467 printf 格式符与参数不匹配 | 逐行核对 `%s` 数量 = 参数个数；目视表头无重复 |
| 3 | L554 `daemon_log_line` 死代码引用 `$1` | `--daemon` 启动后持续运行 1 分钟无报错 |
| 4 | `--log 100` 参数丢失 | `htop-s --log 100` 输出 100 行 |
| 5 | L409 `/proc/loadavg` 第 4 字段错位 | 对照 `cat /proc/loadavg`，进程数显示正确 |
| 6 | `mapfile` 需 bash4 / `date +%s%N` busybox 不支持 | 在 CentOS 7（bash 4.2）+ Alpine（bash 5）均通过 |
| 7 | 日志轮转只在启动执行 | 手动改系统日期跨天，验证日志自动切分 |
| 8 | `ps pcpu` 生命周期均值失真 | 用 `stress-ng --cpu 2` 对照 `top` 输出，偏差 < 15% |
| 9 | 每帧 3 次 `ss -tan` 性能问题 | 造 5000 连接，`time` 验证单帧 < 200ms |
| 10 | `\033[2J` 清屏闪屏 | 退出后终端历史完整保留 |
| 11 | `hr()` 写死 60 列 | resize 终端窗口，布局自动重排 |
| 12 | CPU 漏 steal/guest | 对照 `top` 的 `st` 列 |
| 13 | 英文模式硬编码中文 | `-e` 模式下全屏无中文字符 |

### 15.2 功能验收

| 项 | 标准 |
|---|---|
| 面板刷新 | 2 秒间隔下 CPU/带宽数值连续变化，无卡顿无闪烁 |
| 配额统计 | 手动设置 `--quota 1G`，用 `dd` 传输 500MB，面板显示涨幅误差 < 2% |
| 跨重启（nft） | 重启服务器，本期累计流量不减少 |
| 跨重启（proc） | 重启服务器，面板显示"数据不完整"标记 |
| 告警触发 | `stress-ng` 压满 CPU，15 秒内出现 `cpu` 告警 |
| 告警恢复 | 停止压测，30 秒内出现"已恢复" |
| 服务自启 | `reboot` 后 `systemctl is-active htop-s` 返回 active |
| 单实例 | 连续两次 `--daemon`，第二次拒绝启动并提示 PID |
| 端口映射 | `p` 键展开后，`ss -tlnp` 交叉验证端口与进程一致 |
| 降级 | 手动重命名 `df` 后，磁盘分区显示 N/A 且脚本不崩 |

### 15.3 性能基准

| 场景 | 目标 |
|---|---|
| 空闲机器，2 秒刷新 | 单帧渲染 < 80ms，CPU 占用 < 1% |
| 1000 连接，2 秒刷新 | 单帧渲染 < 120ms |
| 10000 连接，2 秒刷新 | 单帧渲染 < 250ms |
| 常驻内存 | 面板 < 8MB，daemon < 4MB |
| 长跑 7 天 | 内存无增长（RSS 波动 < 10%），无僵尸子进程 |

**测试方法**：造连接用 `python3 -c` 批量 socket，或用 `nc` 循环；
CPU 占用用面板自身分区反查（自监控）。

### 15.4 兼容性矩阵

| 发行版 | bash | 验证重点 |
|---|---|---|
| Debian 11/12 | 5.1 / 5.2 | 基准 |
| Ubuntu 20.04/22.04 | 5.0 / 5.1 | 基准 |
| CentOS 7 | 4.2 | 无 `ss`、老 `df`、systemd 219 |
| Rocky/AlmaLinux 8/9 | 4.4 / 5.1 | 基准 |
| Alpine 3.18+ | 需 `apk add bash` | `date` 无 `-d`、awk 为 busybox |

每台机器先跑 `htop-s --check`，全部项目 OK 或合理跳过才算通过。

---

## 16. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| nftables 与现有防火墙冲突 | 可能影响业务流量 | 只建独立 table，policy accept 无 verdict；README 明确说明；卸载彻底清理。**上线前先在非生产机验证** |
| 非 root 运行时功能受限 | 无法建 nft、看不到其他用户进程端口 | `--check` 明确提示；面板对应位置标注"需要 root" |
| 长时间运行内存泄漏 | daemon 吃掉服务器内存 | `MemoryMax=64M` 硬限制 + 环形缓冲定长；7 天长跑测试作为验收项 |
| 采样本身消耗资源 | 监控变成负担 | 分帧调度 + CPUQuota 限制 + 性能基准作为验收项 |
| 跨重启流量在 proc 模式丢失 | 配额统计不准 | nft 增强为主推；proc 模式明确标注"数据不完整" |
| awk 方言差异 | 数值解析错误 | 只用 POSIX awk 子集；Alpine/CentOS 实测 |
| 终端宽度极窄 | 布局错乱 | 紧凑模式 + 最小宽度提示 |
| 日志占满磁盘 | 服务异常 | 按天切分 + 保留期清理 + 单日上限 |

---

## 17. 里程碑与任务拆解

### M1 采集内核（最优先，决定成败）

1. 能力探测框架 + `--check`
2. 时钟源（`/proc/uptime`）、单位转换、格式化工具函数
3. CPU / 内存 / 负载 采集函数
4. `/proc/net/dev` 网络采集 + 差分
5. `/proc/net/tcp` 解析 + 地址/端口/状态码解码
6. 自测：在 4 个发行版上 `--check` 全绿

### M2 渲染与交互

7. 备用屏缓冲、颜色降级、宽度自适应、SIGWINCH
8. 12 个分区渲染 + 进度条 + sparkline
9. 键盘输入（含 `stty` 不可用降级）
10. 分帧调度器
11. 自测：性能基准达标

### M3 进程与协议栈

12. 进程差值法 CPU + PID 复用防护
13. 磁盘容量/inode/IO
14. `/proc/net/snmp` + `netstat` 协议栈指标
15. conntrack、温度
16. 端口 → 进程映射（`p` 键）
17. 自测：与 `top`/`ss`/`df` 交叉验证

### M4 流量与配额

18. state 文件读写 + 原子写
19. 周期滚动（纯算术，不依赖 `date -d`）
20. nftables 表管理（创建/读取/重建/清理）
21. 双模式累计算法 + 重启判定
22. 配额显示与月末预估
23. 自测：`dd` 灌流量验证误差 < 2%

### M5 后台与告警

24. daemon 循环、单实例保护、日志按天切分
25. 告警状态机 + 持久化 + 本地日志
26. `NOTIFY_CMD` 钩子
27. systemd 单元 + `--install` / `--uninstall` / `--upgrade`
28. `--status` / `--today` / `--month` / `--history`
29. 自测：重启后自启、告警触发与恢复

### M6 收尾

30. 全命令参数解析重构 + 冲突检测
31. 中英双语 + ASCII 模式完整性检查
32. 兼容性矩阵全量验证
33. 使用手册（《htop-s 使用手册》）校对
34. 缺陷回归 13 项逐条确认

---

## 附录 A：文件路径总表

| 用途 | root | 普通用户 |
|---|---|---|
| 可执行文件 | `/usr/local/bin/htop-s` | 任意路径 |
| 配置 | `/etc/htop-s/config` | `~/.config/htop-s/config` |
| 状态 | `/var/lib/htop-s/state` | `~/.local/state/htop-s/state` |
| 采集日志 | `/var/log/htop-s/collect-*.csv` | `~/.local/share/htop-s/log/` |
| 告警日志 | `/var/log/htop-s/alert-*.log` | 同上 |
| PID | `/var/run/htop-s.pid` | `${XDG_RUNTIME_DIR:-/tmp}/htop-s-$UID.pid` |
| systemd | `/etc/systemd/system/htop-s.service` | — |
| nft 表 | `inet htop_s` | — |

## 附录 B：配置文件格式

`/etc/htop-s/config`，`key=value` 每行一条，`#` 开头为注释：

```
# htop-s 配置
iface=eth0
interval=2
quota=1024G
reset_day=1
keep_days=30
acct=nft
alert_cpu=90
alert_mem=90
alert_disk=90
alert_syn=100
notify_cmd=
lang=zh
```

优先级：**命令行参数 > 环境变量 > 配置文件 > 内置默认**。

---

## 18. 发布与分发

### 18.1 仓库配置

| 项 | 值 |
|---|---|
| 仓库 | `zhang123999-qq/htop-s` |
| 可见性 | **Public**（必须——curl 匿名拉取 Release 资源要求公开） |
| License | MIT |
| Topics | linux monitoring bash htop terminal tui devops sysadmin tcp netstat shell-script server |
| 默认分支 | `main` |

### 18.2 版本号规则

采用语义化版本 `MAJOR.MINOR.PATCH`，**脚本内不带 `v`，Git tag 带 `v`**：

- 脚本 `VERSION="0.0.1"` ↔ tag `v0.0.1`
- 版本比较在 `version_newer()` 中按三段数值比较，不要引入带后缀的版本（如 `0.0.1-beta`）
  —— 现有实现只解析三段数字，遇到后缀会被 `+0` 吞掉

不吹版本号：0.0.x 表示「功能完整但未在真实生产环境长期验证」，等实际跑过一段时间再进 0.1。

### 18.3 Release 产物

每次发版上传三个 asset，**文件名必须严格一致**（下载 URL 直接由文件名拼出）：

| Asset | 说明 |
|---|---|
| `htop-s` | 主脚本，需带可执行位 |
| `install.sh` | 一键安装器 |
| `htop-s.sha256` | `sha256sum htop-s install.sh` 的输出 |

`install.sh` 会用 `${URL}.sha256` 去取校验和，所以校验和文件名必须是 `htop-s.sha256`。

### 18.4 固定下载入口

GitHub 提供永不变化的重定向入口，因此文档里可以写死一条命令：

```
https://github.com/<owner>/<repo>/releases/latest/download/<asset>
```

它永远指向最新 Release；指定版本时用
`https://github.com/<owner>/<repo>/releases/download/v<VER>/<asset>`。

### 18.5 发版流程

```bash
# 1. 改版本号
$EDITOR htop-s              # VERSION="0.0.2"

# 2. 自测
htop-s --selftest
bash tests/run-tests.sh

# 3. 提交
git add -A && git commit -m "htop-s 0.0.2"
git push origin main

# 4. 构建产物
rm -rf dist && mkdir dist
cp htop-s dist/htop-s && cp install.sh dist/install.sh
chmod +x dist/htop-s dist/install.sh
(cd dist && sha256sum htop-s install.sh > htop-s.sha256)

# 5. 打 tag
git tag -a v0.0.2 -m "htop-s 0.0.2"
git push origin v0.0.2

# 6. 发布
gh release create v0.0.2 dist/htop-s dist/install.sh dist/htop-s.sha256 \
  --title "v0.0.2" --notes-file dist/notes.md

# 7. 验证线上可下
curl -fsSL -x http://127.0.0.1:10808 \
  https://github.com/zhang123999-qq/htop-s/releases/latest/download/htop-s | head -1
```

### 18.6 代理

网络受限环境下，git / gh / curl 都走同一个代理：

```bash
export https_proxy=http://127.0.0.1:10808
export http_proxy=http://127.0.0.1:10808
```

脚本内的下载代理是独立配置项（`--proxy` / 配置文件的 `proxy=`），
优先级：`--proxy` 参数 > 配置文件 > 环境变量 > 无代理。

### 18.7 更新链路的三重保护

`--update` 在覆盖前必须依次通过：

1. `bash -n` 语法校验
2. 文件内 `VERSION` 必须与请求版本一致
3. 覆盖前备份为 `$BIN_PATH.bak`

任一环节失败即中止，**绝不在校验未通过时覆盖现有文件**。
