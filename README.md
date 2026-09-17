# htop-s

Linux 服务器实时监控终端面板 —— 单文件、零依赖、SSH 直连可用。

在服务器上敲一个命令就能看到 CPU、内存、磁盘、网络流量、TCP/UDP 连接和进程的全景实时状态，
并提供后台常驻采集、开机自启、月流量配额统计和阈值告警。

```
scp htop-s root@server:/usr/local/bin/ && ssh root@server
chmod +x /usr/local/bin/htop-s && htop-s
```

---

## 特点

| | |
|---|---|
| **单文件零依赖** | 只有 `htop-s` 一个文件，不需要安装任何包，不需要联网 |
| **纯 `/proc` `/sys` 采集** | 不用 `ss` / `netstat` / `ps` / `free` / `iostat`，比传统脚本快一个数量级 |
| **兼容广泛** | bash 3.2+ / POSIX awk，实测 Debian、Ubuntu、CentOS 7、Rocky、Alma、Alpine |
| **性能可控** | 分帧调度（快 5s / 中 10s / 慢 60s），空闲机器面板占用约 0.6% CPU |
| **流量配额** | 支持 nftables 精确计数，跨服务器重启不丢；无 nft 时自动回退 |
| **明确告警** | 18 条内置规则，本地告警日志 + 可插拔通知钩子 |
| **安全** | nftables 只建独立表 `inet htop_s`，绝不修改现有防火墙规则 |

---

## 文件与目录结构

### 交付文件（随仓库分发）

| 文件 | 说明 |
|---|---|
| `htop-s` | **主程序**，单文件 bash 脚本，即为最终交付物 |
| `install.sh` | curl 一键安装器（环境检查 → 下载 → 三重校验 → 安装） |
| `htop-s-开发方案.md` | 实现规格说明书：架构、数据源、算法、兼容性约束、测试验收 |
| `htop-s-使用手册.md` | 部署与使用手册：命令、界面解读、告警配置、巡检 SOP、FAQ |
| `README.md` / `LICENSE` | 本说明与 MIT 许可证 |

`htop-s` 是唯一源文件，**没有构建步骤**，改完直接跑。

### 本地目录（不随仓库分发）

| 目录 | 说明 |
|---|---|
| `tests/` | 集成测试套件、mock `/proc` 夹具、版本号一致性检查 |
| `docs/internal/` | 本地开发文档：自测报告、真实环境测试报告、修复报告、渲染性能分析 |
| `.build/` | 构建脚手架：`p1`~`p4` 分片（`cat p1 p2 p3 p4 > htop-s` 即得主程序）与发布说明 |
| `dist/` | 发布产物（由 `htop-s` + `install.sh` 现场生成，含 `sha256`） |
| `.archive/` | 已从工作目录剔除的历史文件归档（旧版脚本、构建中间产物），可随时找回 |

> **不分发范围**：`tests/`、`docs/internal/`、`.build/`、`dist/`、`.archive/` 均已列入
> `.gitignore`，**不随仓库分发**；仓库对外只提供上表中的交付文件。
> 只拿到单文件时，用 `htop-s --selftest` 做验证（内置 **51 项**自测，不依赖外部文件）。

---

## 安装

### 一键安装（推荐）

```bash
# 装到 /usr/local/bin
curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash

# 顺带装好开机自启
curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash -s -- --service

# 指定版本
curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash -s -- -v 0.0.5

# 国内网络走代理
curl -fsSL -x http://127.0.0.1:10808 https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash
```

`releases/latest/download/` 是 GitHub 的固定入口，永远指向最新版，命令不用改。

### 最简形式（只取一个文件）

```bash
sudo curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/htop-s -o /usr/local/bin/htop-s
sudo chmod +x /usr/local/bin/htop-s
htop-s
```

### 手动部署（不需要 root）

```bash
scp htop-s user@server:/tmp/ && ssh user@server 'chmod +x /tmp/htop-s && /tmp/htop-s'
```

### 更新与卸载

```bash
htop-s --check-update            # 看看有没有新版本
sudo htop-s --update             # 从 Release 拉取最新版并重启服务
sudo htop-s --update=0.0.5       # 更新到指定版本
sudo htop-s --update --force     # 版本相同时也强制重装

sudo htop-s --uninstall          # 移除服务与脚本, 保留日志与流量数据
sudo htop-s --uninstall --purge  # 彻底清理
```

自更新有三重保护：下载后先做语法校验 → 再比对文件内版本号 → 通过才覆盖，且先备份 `.bak`。

## 快速上手

```bash
# 1. 环境自检 —— 第一次上某台机器先跑这个
htop-s --check

# 2. 看一眼
htop-s

# 3. 安装 + 开机自启（需要 root）
sudo htop-s --install

# 4. 设置月流量配额
htop-s --quota 1024G --reset-day 1

# 5. 启用 nftables 精确流量统计（跨重启不丢）
sudo htop-s --acct on

# 6. 看今天的汇总
htop-s --today
```

非交互场景（脚本 / 监控系统）：

```bash
htop-s -n                 # 单次快照, 纯文本
htop-s -n -p              # 快照 + 端口到进程映射
htop-s --export           # 结构化 CSV, 便于程序解析
```

完整命令见 `htop-s --help` 或《使用手册》。

---

## 界面

面板分为 14 个区域，从上到下：主机信息 → CPU（总/每核/steal）→ 负载 → 内存/换页 →
磁盘容量/IO/inode → 网卡累计与实时带宽 + 曲线 → 流量配额 → TCP 状态 → UDP →
监听端口与 TOP 对端 → 进程 TOP。

按键：`q` 退出 · `空格` 暂停 · `c/m/n/i` 排序（CPU/内存/连接数/IO）· `1` 每核 · `p` 端口映射 · `?` 帮助

终端宽度不足 60 列时自动进入紧凑模式（隐藏每核、端口映射、磁盘 IO 三个次要分区）。

几个值得注意的读数：

- **负载看 `(x.xx/核)`** —— 裸负载没有意义，8 核机器负载 6.0 是正常的
- **`steal`** —— VPS 上被宿主机抢占的 CPU，物理机恒为 0
- **`CLOSE_WAIT` 高 = 应用有 bug**（漏了 `close()`），而 `TIME_WAIT` 高只是短连接频繁
- **`SYN_RECV` 上百 = 疑似 SYN Flood**
- **inode 满** 会导致磁盘还有空间也写不进去，删大文件没用
- **D 状态进程** 红色高亮，是「服务器假死」最典型的信号

---

## 测试

> 本节依赖本地 `tests/` 目录，而该目录**不随仓库分发**（见 `.gitignore`）。
> 克隆仓库后若没有 `tests/`，直接用 `htop-s --selftest` 验证即可——
> 内置自测不依赖任何外部文件。

测试不依赖真实 Linux：`tests/make-mock.sh` 会生成一套真实格式的 mock `/proc` 数据，
脚本通过 `HT_S_PROC` / `HT_S_ROOT` / `HT_S_ETC` 环境变量指向它，因此在 Windows / macOS 上
也能验证全部解析逻辑。

```bash
bash tests/make-mock.sh     # 生成测试夹具
bash tests/run-tests.sh     # 跑集成测试

# 手工验证
HT_S_PROC=tests/mock/proc HT_S_ROOT=tests/mock/sys HT_S_ETC=tests/mock/etc \
  PATH=tests/mock/bin:$PATH bash htop-s -n
```

内置自测（含 bash 3.2 兼容性静态扫描、i18n 变量完整性、单位换算、日期算术、CPU 差分、TCP 小端序解析、默认网关解码、进程排序键 n/i 等 **51 项**）：

```bash
htop-s --selftest
```

**注意**：Windows 沙箱下每次 fork 约 400ms、每次 awk 约 700ms（Linux 上约 0.3ms），
集成测试需要 20 分钟以上；在 Linux 上跑只需十几秒。

---

## 设计要点

- **分层**：采集层（`/proc` `/sys`）→ 聚合层（awk 一次算完多键聚合）→ 缓存层（分帧）→ 渲染层（备用屏缓冲）
- **分帧调度**：秒级指标随面板刷新（默认 1s），磁盘 IO / TOP 进程 10s，磁盘容量 / 温度 / 系统信息 60s。
  避免「监控脚本自己拖慢服务器」
- **双进程模型**：面板只读状态文件，daemon 独占写，互不干扰
- **时钟源**：用 `/proc/uptime`（10ms 精度）而非 `date +%s%N`，busybox 也支持
- **免 fork 渲染**：`printf -v` 直接写变量，每帧省掉约 50 次子 shell
- **进程 CPU 差值法**：按 `/proc/[pid]/stat` 两次采样算差值，并用 `starttime` 防 PID 复用
- **流量原子落盘**：临时文件 + `mv`，断电不会写坏状态文件

完整设计见《htop-s 开发方案》。

---

## 环境要求

- Linux（依赖 `/proc`、`/sys`）
- bash >= 3.2
- POSIX awk（gawk / mawk / busybox awk 均可）
- coreutils（`df`、`sort`、`tail` 等）
- 可选：`nft`（流量精确统计）、`systemd`（开机自启）、`tput`（颜色与终端尺寸）

不支持 OpenWrt / busybox ash（无 bash）。Alpine 需 `apk add bash`。

---

## 卸载

```bash
sudo htop-s --uninstall          # 移除服务与脚本, 保留日志与流量数据
sudo htop-s --uninstall --purge  # 彻底清理
```
