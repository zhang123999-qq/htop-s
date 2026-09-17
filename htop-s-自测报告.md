# htop-s 自测报告

> 版本：0.0.2　|　报告日期：2026-09-17　|　对应规格：《htop-s 开发方案 v2.0》

---

## 0. 结论摘要

| 项 | 结果 |
|---|---|
| 硬性约束（10 项） | **全部满足** |
| 架构分层（5 层） | **全部实现** |
| 核心功能规格（8 组） | **全部实现** |
| 旧版缺陷回归（13 项） | **13/13 通过** |
| 内置自测 | **50 项全部通过** |
| 集成测试 | **见 §5** |
| 真实发行版验证 | **未完成** —— 见 §8 |
| Linux 性能实测 | **未完成** —— 见 §7 |

**一句话**：规格里的功能与约束已全部落地并通过可在本机验证的全部测试；
**唯一缺口是没有真实 Linux 服务器上跑过**，性能基准与兼容性矩阵因此只有估算和静态核对，没有实测数据。

---

## 1. 测试环境与范围

| 项 | 值 |
|---|---|
| 开发/测试主机 | Windows 10 (MINGW64_NT-10.0-19045) |
| 运行时 | GNU bash 5.3.15 (cygwin) + GNU Awk 5.4.0 |
| 目标平台 | **Linux**（脚本依赖 `/proc`、`/sys`） |
| 测试方式 | 构造真实格式的 mock `/proc` `/sys` `/etc` 夹具，通过 `HT_S_PROC` / `HT_S_ROOT` / `HT_S_ETC` 重定向根目录 |

**为什么这样测**：本机不是 Linux，无法直接跑。`tests/make-mock.sh` 按真实内核格式生成
`/proc/stat`、`meminfo`、`loadavg`、`vmstat`、`net/dev`、`net/tcp`、`net/tcp6`、`net/udp`、
`net/snmp`、`net/netstat`、`diskstats`、`sys/net/netfilter/*`、`[pid]/stat`、`[pid]/cmdline`
以及 `df` 桩程序，覆盖全部解析路径。

**这个方式的边界**：能验证解析逻辑、计算公式、降级行为、命令接口、daemon 循环；
**不能**验证真实内核字段差异、真实 `/proc/[pid]/fd` 软链、真实 nftables、真实 systemd。

### 环境关键事实（影响所有耗时数据）

在这台 Windows 沙箱上实测：

| 操作 | 本机耗时 | Linux 典型值 | 倍数 |
|---|---|---|---|
| `bash -c 'exit 0'` | 2.2 s | ~3 ms | ~700× |
| `$(true)` 子 shell | 420 ms | ~0.3 ms | ~1400× |
| `awk 'BEGIN{print 1}'` | 740 ms | ~0.5 ms | ~1500× |

**本报告里所有"秒级"耗时都是这个环境的产物，不代表脚本在 Linux 上的性能。**
脚本在 Linux 上的表现见 §7 的估算。

---

## 2. 环境自检 `--check`

```
────────────────────────────────────────────────────────────────────────────────────────────────────
  htop-s 环境自检 v0.0.2
────────────────────────────────────────────────────────────────────────────────────────────────────
  系统      MINGW64_NT-10.0-19045 3.6.9-b4195d69.x86_64 x86_64 OK
  发行版   Debian GNU/Linux 12 (bookworm) OK
  bash        5.3.15(1)-release              OK   需要 >= 3.2
  awk         GNU Awk 5.4.0, API 4.1 ...     OK   POSIX 兼容即可
  时钟源   .../proc/uptime 363723.45         OK   精度 10ms
  页大小   65536                             OK
  CLK_TCK     1000                           OK
  CPU 核数  4                                OK   来自 .../proc/stat
  进程采集  16 个进程                        OK   .../proc/[pid]/stat
  内存      .../proc/meminfo                 OK
  磁盘容量  df -PT                           OK   5 行输出
  磁盘 IO   .../proc/diskstats               OK   整盘: dm-0 sda
  网卡      eth0 (未知)                      OK
  TCP 采集  .../proc/net/tcp                 OK   16 个连接
  协议栈    .../proc/net/netstat             OK   表头动态匹配
  UDP 统计  .../proc/net/snmp                OK
  conntrack   312 / 65536                    OK
  温度      54°C                             OK
  nftables    命令缺失                       SKIP 使用基础模式 /proc/net/dev
  systemd     不可用                         SKIP 无法安装服务
  ping        不可用                         SKIP netdown 规则自动跳过
  下载工具  均不可用                         SKIP 不影响监控, 仅无法在线更新
  默认网关   缺失                            SKIP .../proc/net/route 不可读
  终端宽度 100 列                            OK
────────────────────────────────────────────────────────────────────────────────────────────────────
  结论: 核心功能可用, 3 项因环境缺失自动降级 (见上方 SKIP 说明)
  流量计数模式: proc
```

**对照规格**：自检覆盖了规格 §13.2 要求的全部条目（数据源、命令、权限、时钟源、页大小、
CLK_TCK、协议栈表头匹配、conntrack、温度、nftables、systemd、终端宽度）。
`SKIP` 与 `FAIL` 严格区分：**SKIP 是环境本来没有，FAIL 是脚本用不了**。

> 注：上表中的 SKIP（nft / systemd / ping / 下载工具 / 网关）是因为本机不是 Linux、
> 且测试时 PATH 只保留了 `/usr/bin:/bin`。在真实服务器上这些应为 OK。

---

## 3. 内置自测 `--selftest`（50 项，全部通过）

```
──────────────────────────────────────────────────────────────────────
  htop-s 内置自测 v0.0.2
──────────────────────────────────────────────────────────────────────

  1. bash 3.2 兼容性扫描
  [PASS] 无 bash4 专有语法

  2. 单位换算
  [PASS] human_bytes 0            [PASS] human_bytes 1024
  [PASS] human_bytes 1023         [PASS] human_bytes 1536
  [PASS] human_bytes 1048576      [PASS] human_bytes 1073741824
  [PASS] human_bytes 非数字       [PASS] human_bytes 负数

  3. 进度条
  [PASS] bar 0% / 50% / 100% / 超界 150% / 负数 -50%     (5 项)

  4. 日期算术 (纯 shell, 不依赖 date -d)
  [PASS] 闰年 2024-02  [PASS] 平年 2026-02  [PASS] 世纪闰年 2000-02
  [PASS] 非闰 1900-02  [PASS] 31 天月份     [PASS] 30 天月份
  [PASS] 跨年天序号差  [PASS] 平年 2月28->3月1  [PASS] 闰年 2月28->3月1   (9 项)

  5. CPU 差分计算
  [PASS] busy% / user% / sys% / io% / 无变化时归零 / 空输入不报错        (6 项)

  6. 带宽曲线
  [PASS] 长度正确 / 不足宽度不补位 / 空输入                            (3 项)

  7. /proc/net/tcp 解析
  [PASS] 总数/EST/SYN/SYN_RECV/LISTEN   [PASS] 对端 IP 小端序解码
  [PASS] 监听端口十六进制解码                                          (3 项)

  8. 负载与进程数解析
  [PASS] load1   [PASS] 运行中进程数   [PASS] 总进程数                   (3 项)

  9. 网卡流量解析
  [PASS] eth0 精确匹配(不误配 eth0.100)   [PASS] 多网卡求和             (2 项)

  10. 其他
  [PASS] 状态文件路径按身份隔离   [PASS] nft 表名固定
  [PASS] PID 复用防护字段存在                                          (3 项)

  11. i18n 变量完整性 (set -u 防护)
  [PASS] 所有 T_ 变量均有定义                                          (1 项)

  12. 默认网关解析
  [PASS] 网关小端序解码   [PASS] 无 route 文件时为空                    (2 项)

  13. 进程排序键 n / i
  [PASS] n 排序按连接数降序   [PASS] n 模式指标列=连接数
  [PASS] i 排序按 IO 降序     [PASS] i 模式指标列已格式化               (4 项)

──────────────────────────────────────────────────────────────────────
  50 项全部通过
──────────────────────────────────────────────────────────────────────
```

**第 1 项是规格 §一 的自动化守门人**：它扫描脚本自身，发现
`declare -A` / `mapfile` / `readarray` / `&>>` / `${var^^}` / `date +%s%N` / `local -n`
中任意一个就报错。

**第 11 项是旧版崩溃根因的守门人**：提取所有被引用的 `T_` 变量与所有被赋值的 `T_` 变量做差集，
差集非空即失败（旧版正是因为 `${T_CPU}` 未定义 + `set -u` 直接崩）。

> 开发过程中第 11 项真实抓到过一次 `T_PORTMAP` 未定义——按 `p` 键展开端口映射会崩。

---

## 4. 规格符合性逐条对照

### 4.1 硬性约束（规格 §一，10 项）

| # | 约束 | 实现 | 验证方式 |
|---|---|---|---|
| 1 | bash 3.2+，禁用 bash4 特性 | 全部禁用 | 自测第 1 项自动扫描 |
| 2 | 零外部依赖（bash+awk+coreutils） | 数据全部自解析 `/proc` `/sys`，**不用** `ss`/`netstat`/`ps`/`free`/`iostat` | `grep` 静态核对 |
| 3 | 禁用 `date +%s%N`，用 `/proc/uptime` | `read_uptime()` 统一提供时钟 | 自测第 1 项 + 代码核对 |
| 4 | 只用 POSIX awk 子集 | 无 `gensub`/`asort`/`FPAT`/三参数 `match` | `grep -E` 静态扫描为空 |
| 5 | nftables 增强模式 | 独立表 `inet htop_s`，`policy accept`，只含 `counter` | 代码核对 |
| 6 | 告警只写本地日志 + `NOTIFY_CMD` 钩子 | `printf '%s' "$line" \| eval "$NOTIFY_CMD"` | 代码核对 |
| 7 | 面板只读 state，daemon 独占写 | 面板路径无任何 `state_save` 调用 | 代码核对 |
| 8 | state 原子写 | 临时文件 + 同目录 `mv` | 集成测试「无 .tmp 残留」 |
| 9 | 备用屏缓冲，禁 `\033[2J` | `\033[?1049h` 进入，`\033[?1049l` 恢复 | `grep '2J'` 为空 |
| 10 | trap EXIT/INT/TERM/HUP + `stty sane` | `cleanup_all` 中 `stty sane` | 代码核对 |

**关于约束 5 的安全性**（规格特别强调）：实现只做三件事——
`nft add table inet htop_s`、建两条链（`prerouting` + `postrouting`，hook 是必须的，
否则链里的 counter 永远不会执行）、按网卡挂 `counter` 规则。
**不执行 `flush ruleset`、不动其他 table、不动 iptables 兼容表**（自测/集成测试均对此有断言）。
卸载时 `nft delete table inet htop_s` 完整还原。

### 4.2 架构分层（规格 §二，5 层）

| 层 | 实现位置 | 说明 |
|---|---|---|
| L5 输出层 | `p_line` + `enter_screen`/`leave_screen` | 备用屏、宽度自适应、颜色降级、中英双语 |
| L4 渲染层 | `render()` | 14 个分区、进度条、sparkline、阈值配色 |
| L3 缓存层 | `dispatch_frames()` + `CV_*`/`MV_*`/`SV_*` | 快/中/慢三帧调度 + 跨帧差分状态 |
| L2 聚合层 | 各采集函数内的 awk | 多键聚合一次算完，shell 只拼字符串 |
| L1 采集层 | `read_*()` / `*_delta()` | 读 `/proc` `/sys`、能力探测、回退链 |

**性能命门（规格特别标注）**：`proc_top` 用**一次 awk** 完成「读全部进程 stat + 差分 +
PID 复用校验 + 打分 + Top-N 选择」，`tcp_scan` 用**一次 awk** 完成「状态分布 + TOP 对端 +
TOP 监听端口」，`alert_scan` 用**一次 awk** 算出 19 条规则的全部命中标志。

### 4.3 核心功能（规格 §三，8 组）

| 组 | 规格要求 | 实现 |
|---|---|---|
| 1 分帧调度 | 快 2s / 中 10s / 慢 60s | `dispatch_frames()` 按 `/proc/uptime` 到期判断，不用定时器 |
| 2 数据采集 | CPU 口径 `100=us+sy+ni+id+wa+hi+si+st`、内存 `MemTotal−MemAvailable`、Cached 修正、loadavg 第 4 字段切分、`df -P`、diskstats 整盘、`iface:` 精确匹配、TCP 状态码映射、snmp 跳表头、netstat 按表头名查列号、pid stat 括号解析、温度 ÷1000、conntrack | 全部实现，集成测试逐项断言 |
| 3 进程视图 | 差值法 CPU、starttime 防复用、D 状态高亮、cmdline 优先、排序 c/m/n/i | 全部实现；n/i 为本轮补齐 |
| 4 流量配额 | 双模式、state 原子写、纯算术周期滚动、月末预估 | 全部实现 |
| 5 终端界面 | 14 分区、sparkline、颜色阈值、宽度自适应、SIGWINCH、<60 列紧凑、全套键位 | 全部实现；SIGWINCH 与紧凑模式为本轮补齐 |
| 6 后台服务 | systemd + 资源限制、PID+flock 单实例、按天切分、每轮轮转检查 | 全部实现 |
| 7 告警引擎 | §12.1 规则表全部、状态机、持久化、日志格式、NOTIFY_CMD | 19 条规则（含本轮补齐的 `netdown`） |
| 8 命令接口 | §13.1 全表、`--check`、参数解析重构 | 全部实现，另有 `--update`/`--proxy`/`--check-update` |

**告警规则对照**（规格 §12.1 共 18 条 + 实现的 1 条扩展）：

`cpu` `mem` `swap` `disk` `inode` `load` `conntrack` `syn` `timewait` `closewait`
`listen_drop` `retrans` `nic_err` `quota80` `quota100` `dstate` **`netdown`** `oom`
→ 全部实现；另有扩展规则 `syn_retrans`（SYN 重传数）与 `udp_err`（UDP 收包错误）。

### 4.4 本轮补齐的 4 项差距

上一版对照规格审计后发现的真实缺口，本轮已全部补齐并补上测试覆盖：

| # | 规格要求 | 本轮实现 |
|---|---|---|
| 1 | 进程排序键 `n`(网络) / `i`(IO) | 新增 `proc_conn_map()`（扫 fd 统计 socket 数）与 `proc_io_map()`（读 `/proc/[pid]/io` 做速率差分）；`proc_top` 支持两种打分；渲染层增加独立指标列（表头随模式切换为 `CONN` / `IO`） |
| 2 | 告警规则 `netdown` 断网检测 | 新增 `read_gateway()`（解析 `/proc/net/route` 小端序字段）；`alert_scan` 中带 5 秒限频调用 `ping -c1 -W1`；**无 ping 或无网关时该规则自动跳过并在 `--check` 标注 SKIP** |
| 3 | `<60 列紧凑模式` | `render()` 中按宽度置 `COMPACT`，隐藏每核视图、端口映射、磁盘 IO 三个次要分区；标题栏显示 `[紧凑]` |
| 4 | `SIGWINCH` 重绘 | `interactive_loop` 中 `trap 'WINCH=1' WINCH`，主循环检测到即 `continue` 立刻重绘，不等剩余间隔 |

**设计取舍说明**：`n` 与 `i` 的数据源需要遍历 `/proc/[pid]/fd` 与 `/proc/[pid]/io`，
开销远大于读单个文件，因此**只在用户按下对应按键时按需采集**（与既有 `p` 端口映射一致），
不在每帧执行。这是刻意的：监控工具不能因为一个排序视图就把服务器拖慢。

---

## 5. 集成测试

测试套件 `tests/run-tests.sh`，在 mock 环境下跑遍全部命令与代码路径。

### 5.1 覆盖范围

| 节 | 内容 | 用例数 |
|---|---|---|
| 1 | 语法与静态检查（`bash -n`、bash4 语法、shebang、`set -u`、nft 独立表、无 `flush ruleset`） | 6 |
| 2 | 自检与自测（`--check`、`--selftest`、`-V`、`-h`） | 12 |
| 3 | 面板结构（各分区存在性、ANSI 剥离、英文/ASCII/精简/端口映射/紧凑模式） | 23 |
| 4 | 数值正确性（对照 mock 数据逐项核对，见 5.2） | 24 |
| 5 | 导出与状态（`--export` CSV 结构、`--status`、`--acct`） | 10 |
| 6 | 配置命令（`--quota` 各量级、非法值拒绝、`--reset-day` 边界、`--config` 回读） | 16 |
| 7 | 日志/汇总/告警（未采集时、`--test-alert`、`--alert` 回读） | 9 |
| 8 | 无终端保护（拒绝进入交互面板并提示 `-n`） | 2 |
| 9 | 后台采集（启动/单实例/PID 清理/CSV 结构与数值合法性/state 原子写/汇总报告） | 21 |
| 10 | 边界与降级（数据源全缺失、字段畸形、非 root 拒绝） | 7 |
| 11 | 性能计时 | 1 |
| | **合计** | **131** |

### 5.2 数值正确性验证（对照 mock 夹具）

这组用例是**逐值核对**，不是"跑起来不报错"：

| 断言 | mock 输入 | 期望输出 | 验证点 |
|---|---|---|---|
| 累计下行 | `net/dev` eth0 rx=1363400000000 | `↓1.2TB` | 单位换算 |
| 累计上行 | tx=424000000000 | `↑394.8GB` | |
| 内存使用率 | total=16384000kB, avail=7500000kB | `54.2%` | `MemTotal−MemAvailable` 口径 |
| Swap 使用率 | total=2097152kB, free=1680000kB | `19.9%` | |
| TCP 各状态 | 构造 14 条 v4 + 2 条 v6 | `已建立 4` `SYN_RECV 3` `TIME_WAIT 3` `CLOSE_WAIT 2` | 十六进制状态码映射 |
| 对端 IP | `0A00A8C0` | `192.168.0.10` | **小端序解码** |
| 监听端口 | `0016` `01BB` | `22 443` | 十六进制端口 |
| conntrack | 312 / 65536 | `conntrack 312/65536` | |
| 负载与进程数 | `1.24 0.98 0.71 3/512 12345` | `1.24 0.98 0.71` + `进程 3 / 512` | **第 4 字段按 `/` 切分**（旧版缺陷 5） |
| 负载归一 | load1=1.24, 4 核 | `0.31/核` | |
| 磁盘容量 | `df -PT`：`/` 66%、`/data` 21% | 两行正确 | 类型过滤 |
| 过滤 | overlay、tmpfs | **不出现** | 非物理设备过滤 |
| inode | `df -Pi`：最大 12% | `inode 12%` | **列名匹配 `/^IUse%/`**（旧版缺陷 9） |
| 温度 | thermal 54000 | `54°C` | 毫摄氏度 ÷1000 |
| 僵尸进程 | 1 个 `Z` 状态 | `僵尸 1` | |
| D 状态 | kworker 为 `D` | `D 状态进程 (1)` | |
| 进程命令行 | `cmdline` 有值 | `/usr/bin/node /app/server.js` | cmdline 优先于 comm |
| 网卡精确匹配 | eth0=1363400000000, eth0.100=999 | 只取 eth0 | **不误配 `eth0.100`** |

### 5.3 结果

```
=== 结果 ===
  通过: 131   失败: 0

全部测试通过
```

退出码 `0`。**131 项全部通过，零失败。**

其中第 4 节「数值正确性」是逐值核对——每一条断言都对应 mock 夹具里的一个已知输入值
和预期的显示结果，不是"跑起来不报错"这种弱断言。第 9 节「后台采集」实际启动了 daemon
进程、等待它写出真实日志、再校验 CSV 的列数/数值合法性/state 原子性，最后发送 SIGTERM
验证 PID 文件清理。

---

## 6. 旧版缺陷回归（13/13）

| # | 缺陷 | 修复方式 | 回归验证 |
|---|---|---|---|
| 1 | `${T_CPU}`/`${C_CPU_COL}`/`${TITLE_EXTRA}` 未定义 + `set -u` 崩 | 全部变量在 globals 中预初始化 | 自测第 11 项自动比对引用集与定义集 |
| 2 | printf 格式符与参数数量不匹配 | **改为"先拼字符串、再单参数输出"**，从写法上根除 | 集成测试断言输出无 `%s` 残留、行数正确 |
| 3 | `daemon_log_line` 死代码引用 `$1` | 整段重写 | 集成测试 daemon 节全绿 |
| 4 | `--log 100` 参数丢失 | 参数解析改为「选项当场消费并存全局变量」 | 集成测试 `--log` 用例 |
| 5 | `/proc/loadavg` 第 4 字段错位 | `split($4, a, "/")` | 自测第 8 项 + 集成测试 |
| 6 | `mapfile` 需 bash4、`date +%s%N` busybox 不支持 | `while read` 替代；`/proc/uptime` 时钟 | 自测第 1 项自动扫描 |
| 7 | 日志轮转只在启动执行 | 轮转+清理放入每轮循环，按日期变化触发 | 代码核对 |
| 8 | `ps pcpu` 失真 | `/proc/[pid]/stat` 差值法 | 自测第 13 项 |
| 9 | 每帧多次 `ss` | 自解析 `/proc/net/tcp`，一次 awk 出全部指标 | 代码核对 + 性能对比 |
| 10 | `\033[2J` 闪屏 | `\033[?1049h` 备用屏 | 集成测试断言无 `2J` |
| 11 | `hr()` 写死 60 列 | 按 `TERM_COLS` 动态生成并缓存 | 集成测试紧凑模式用例 |
| 12 | CPU 漏 steal/guest | 累加 steal，guest 不重复计 | 自测第 5 项 + 界面显示 |
| 13 | 英文模式硬编码中文 | 全量 i18n 表 | 集成测试 `-e` 用例断言无中文分区名 |

**额外发现并修复的缺陷**（原 13 项之外）：

| 缺陷 | 影响 |
|---|---|
| `disk_inode` 用 `/^IUse/` 匹配列名，同时命中 `IUsed` | inode 显示成 1 亿 % |
| `cpu_delta` 空输入时 awk 的 `END` 重复输出 | 返回两行，解析错位 |
| `--log`/`--alert`/`--history`/`--quota`/`--reset-day`/`--keep`/`--iface` 忘记设置 MODE | 参数被解析后落入交互分支，命令完全无效 |
| `main` 中 `MINIMAL=0` 在 `parse_args` 之后覆盖 `-m` | `-m` 参数失效 |
| `load_config` 用 `[ -z "$ST_QUOTA" ]` 作守卫（默认值 0 非空） | 配置文件永远读不进来 |
| `T_PORTMAP` 未定义 | 按 `p` 键崩溃 |
| 自测的 `comm` 未加 `-u`，多重集比较产生误报 | 自测假阳性 |

---

## 7. 性能

### 7.1 本机实测（不代表 Linux）

| 场景 | 实测 |
|---|---|
| 单帧全流程（快照模式，含固定 `sleep 1`） | 91 ~ 102 秒 |
| 反推外部命令调用次数 | ≈ 210 次（按每次 fork 420 ms 折算） |
| 其中「快帧」部分 | ≈ 32 次调用 |
| 其中「中帧」部分（含 TOP 进程 + cmdline 补全） | ≈ 45 次调用 |

### 7.2 Linux 上的预期（估算，**非实测**）

按 Linux 典型 `fork` 成本 0.2~0.5 ms 计算：

| 指标 | 规格目标 | 估算值 |
|---|---|---|
| 空闲机单帧渲染（快帧） | < 80 ms | **约 15 ~ 25 ms** |
| 1000 连接 | < 120 ms | 约 20 ~ 35 ms（`tcp_scan` 为一次 awk） |
| 10000 连接 | < 250 ms | 约 40 ~ 80 ms |
| 常驻内存（面板） | < 8 MB | bash 进程本身约 3~5 MB，无数组累积 |
| 常驻内存（daemon） | < 4 MB | 同上；环形缓冲定长 120 点 |
| CPU 占用 | < 1% | 2 秒一帧、每帧约 15~25 ms → **约 1%**，临界 |

**已做的性能优化**（这些是实测有效的，与平台无关）：

| 优化 | 效果 |
|---|---|
| 渲染层 `printf -v` 直接写变量，替换全部 `$( )` 调用 | **每帧减少约 50 次子 shell** |
| `alert_scan` 状态读写改纯 shell + 19 条阈值一次 awk 算完 | **每轮从 234 次 fork 降到 8 次** |
| `proc_top` 单次 awk 完成解析+差分+打分+Top-N | 替代 `ps` 的多次调用 |
| 分隔线按宽度缓存 | 每帧少 6 次调用 |
| 分帧调度 | 磁盘容量/温度/系统信息 60 秒才算一次 |

### 7.3 未验证项

- **7 天长跑内存无增长**：未执行。
- **>= 1000 / 10000 连接下的单帧耗时**：未执行（无真实连接环境）。

---

## 8. 兼容性矩阵（**未完成，最重要缺口**）

规格要求逐个发行版跑 `htop-s --check`。**本机不是 Linux，这一项无法完成。**

| 发行版 | bash | 静态核对 | `--check` 实测 |
|---|---|---|---|
| Debian 11/12 | 5.1 / 5.2 | 应通过 | **未验证** |
| Ubuntu 20.04/22.04 | 5.0 / 5.1 | 应通过 | **未验证** |
| CentOS 7 | 4.2 | 应通过（无 `mapfile` 等依赖） | **未验证** |
| Rocky / AlmaLinux 8/9 | 4.4 / 5.1 | 应通过 | **未验证** |
| Alpine 3.18+ | 需 `apk add bash` | 应通过；`date` 无 `-d` 已规避 | **未验证** |

**已知会踩的点**（已在设计上规避，但需实测确认）：
- CentOS 7 的 `df` 版本较老 → 已用 `df -PT || df -P` 双路回退
- Alpine 的 `awk` 是 busybox awk → 已限定 POSIX 子集；但 `printf -v` 是 bash 内建，不受影响
- Alpine 的 `ping` 是 busybox 版 → `-c 1 -W 1` 参数兼容
- CentOS 7 的 `systemd` 是 219 → 单元文件未用新指令（无 `MemoryMax` 兼容性问题；该指令 219 已支持）

### 建议的验证步骤

```bash
# 在每台目标机上
htop-s --check          # 应全部 OK 或合理 SKIP
htop-s --selftest       # 应 50 项全部通过
htop-s                  # 跑 10 分钟, 观察是否有卡顿/花屏
htop-s --status         # 装完服务后确认
```

---

## 9. 未覆盖项与风险

| # | 项 | 状态 | 风险 |
|---|---|---|---|
| 1 | 真实 Linux 上运行 | **未做** | 高——内核字段差异可能触发未预见的问题 |
| 2 | 兼容性矩阵逐一验证 | **未做** | 中 |
| 3 | Linux 性能实测 | **未做** | 中——规格目标未实测确认 |
| 4 | `proc_conn_map` / `port_map`（fd 软链遍历） | **仅静态检查** | 中——Windows 无法创建 `socket:[N]` 软链。逻辑与 `proc_io_map` 同构，后者已测 |
| 5 | nftables 增强模式 | **仅静态检查** | 中——本机无 `nft`。表结构/链 hook/卸载清理均按规格实现 |
| 6 | systemd 服务安装与自启 | **仅静态检查** | 中——本机无 systemd |
| 7 | 跨服务器重启的流量连续性 | **未做** | 中——nft 模式下逻辑已实现（uptime 倒退判定 + 归档累加） |
| 8 | 告警实际触发/恢复时序 | **未做** | 低——状态机逻辑简单，阈值比较已单元测试 |
| 9 | 7 天长跑内存/僵尸进程 | **未做** | 低 |
| 10 | 配额统计误差 < 2% | **未做** | 低——按字节累加，无浮点误差来源 |

**结论**：可以在测试服务器上试用，但**不建议直接上生产**。建议顺序：
测试机 `--check` → `--selftest` → 交互面板跑 30 分钟 → 装服务跑 24 小时 → 再上生产。

---

## 10. 复现方式

```bash
git clone https://github.com/zhang123999-qq/htop-s
cd htop-s

bash tests/make-mock.sh        # 生成 mock /proc /sys /etc 夹具
bash tests/run-tests.sh        # 集成测试

# 手工验证（把根目录指向 mock）
HT_S_PROC=tests/mock/proc HT_S_ROOT=tests/mock/sys HT_S_ETC=tests/mock/etc \
  PATH=tests/mock/bin:$PATH bash htop-s -n

# 内置自测
htop-s --selftest
htop-s --check
```

**注意**：Windows 沙箱下每次 `fork` 约 420 ms，集成测试需 30 分钟以上；
Linux 上约十几秒。
