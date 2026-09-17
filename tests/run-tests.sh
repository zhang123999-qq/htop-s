#!/usr/bin/env bash
# htop-s 集成测试: 在 mock /proc 环境下验证全部命令与代码路径
#
# 设计说明: 每次 bash 启动在 Windows 沙箱下约 2 秒, 因此把断言按"一次调用多断言"组织,
# 避免 70 次进程启动。Linux 上可随意跑。
#
# 用法: bash tests/run-tests.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HTS="$ROOT/htop-s"
MOCK="$ROOT/tests/mock"
SANDBOX="$ROOT/tests/sandbox"

PASS=0
FAIL=0
FAILED_LIST=""

ok()  { PASS=$(( PASS + 1 )); printf '  \033[32m[ok]\033[0m   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); FAILED_LIST="${FAILED_LIST}
    - $1"; printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# 隔离运行环境, 绝不污染真实 HOME
[ -d "$SANDBOX" ] && rm -rf "$SANDBOX" 2>/dev/null
mkdir -p "$SANDBOX/home" "$SANDBOX/run" 
export HOME="$SANDBOX/home"
export XDG_STATE_HOME="$SANDBOX/home/.local/state"
export XDG_CONFIG_HOME="$SANDBOX/home/.config"
export XDG_DATA_HOME="$SANDBOX/home/.local/share"
export XDG_RUNTIME_DIR="$SANDBOX/run"
export PATH="$MOCK/bin:/usr/bin:/bin"
export HT_S_PROC="$MOCK/proc"
export HT_S_ROOT="$MOCK/sys"
export HT_S_ETC="$MOCK/etc"
export COLUMNS=100
unset NO_COLOR

# 所有调用加超时保护, 防止死循环把测试挂住
h() { timeout 240 bash "$HTS" "$@"; }

has()  { printf '%s' "$1" | grep -qF -- "$2"; }
hasnt(){ ! printf '%s' "$1" | grep -qF -- "$2"; }

chk() { if has "$2" "$3"; then ok "$1"; else bad "$1" "未找到 [$3]"; fi; }
chkn(){ if hasnt "$2" "$3"; then ok "$1"; else bad "$1" "不应出现 [$3]"; fi; }
chke(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 [$3] 实际 [$2]"; fi; }

printf '\033[1m=== htop-s 集成测试 ===\033[0m\n'
printf 'mock: %s\n' "$MOCK"

#===============================================================================
head1 '1. 语法与静态检查'
#===============================================================================
if bash -n "$HTS" 2>/dev/null; then ok "bash -n 语法检查"; else bad "bash -n 语法检查"; fi

hits=$(grep -nE 'declare -A|mapfile|readarray|&>>|date \+%s%N|local -n' "$HTS" 2>/dev/null | grep -v 'HT_S_SCAN' | grep -vE '^[0-9]+:[[:space:]]*#')
if [ -z "$hits" ]; then ok "无 bash4 专有语法"; else bad "无 bash4 专有语法" "$(printf '%s' "$hits" | head -3)"; fi

if grep -q '^#!/usr/bin/env bash' "$HTS"; then ok "shebang 正确"; else bad "shebang 正确"; fi
if grep -q 'set -u' "$HTS"; then ok "启用 set -u (未定义变量即报错)"; else bad "启用 set -u"; fi
if grep -q 'nf_tables\|inet htop_s' "$HTS"; then ok "nft 使用独立表 inet htop_s"; else bad "nft 独立表"; fi
if grep -q 'flush ruleset' "$HTS"; then bad "未使用 flush ruleset (危险)"; else ok "未使用 flush ruleset (危险)"; fi

#===============================================================================
head1 '2. 一次性采集 (每个命令只调一次)'
#===============================================================================
CHECK=$(h --check 2>&1);        RC_CHECK=$?
SELFTEST=$(h --selftest 2>&1);  RC_SELFTEST=$?
SNAP=$(h -n 2>&1);              RC_SNAP=$?
SNAP_E=$(h -n -e 2>&1)
SNAP_A=$(h -n -a 2>&1)
SNAP_M=$(h -n -m 2>&1)
SNAP_P=$(h -n -p 2>&1)
SNAP_C=$(COLUMNS=50 h -n 2>&1)
EXPORT=$(h --export 2>&1)
HELP=$(h --help 2>&1)
STATUS=$(h --status 2>&1)
CONFIG0=$(h --config 2>&1)
ACCT=$(h --acct status 2>&1)

chke "--check 退出码 0"        "$RC_CHECK" "0"
chke "--selftest 退出码 0"     "$RC_SELFTEST" "0"
chke "-n 退出码 0"             "$RC_SNAP" "0"
chk  "--selftest 全部通过"     "$SELFTEST" "全部通过"
chk  "--selftest 覆盖 bash4 扫描" "$SELFTEST" "无 bash4 专有语法"
chk  "--selftest 覆盖 i18n 完整性" "$SELFTEST" "所有 T_ 变量均有定义"
chk  "--selftest 覆盖 TCP 解析"    "$SELFTEST" "对端 IP 小端序解码"
chk  "--check 给出结论"        "$CHECK" "结论:"
chk  "--check 检测核数"        "$CHECK" "CPU 核数"
chk  "--check 检测 nft"        "$CHECK" "nftables"
chk  "-h 帮助可用"             "$HELP" "--install"
chk  "-h 含启动命令说明"       "$HELP" "htop-s"

#===============================================================================
head1 '3. 面板结构'
#===============================================================================
chk  "-n 包含 CPU 分区"    "$SNAP" "CPU"
chk  "-n 包含内存分区"     "$SNAP" "内存"
chk  "-n 包含磁盘分区"     "$SNAP" "磁盘"
chk  "-n 包含网卡分区"     "$SNAP" "网卡"
chk  "-n 包含 TCP 分区"    "$SNAP" "TCP"
chk  "-n 包含 UDP 分区"    "$SNAP" "UDP"
chk  "-n 包含进程分区"     "$SNAP" "PID"
chk  "-n 包含告警计数"     "$SNAP" "告警"
chk  "-n 包含负载归一值"   "$SNAP" "/核"
chk  "-n 包含带宽曲线"     "$SNAP" "↓"
chkn "-n 输出已剥离 ANSI"  "$SNAP" $'\033'
chkn "-n 无格式串残留"     "$SNAP" "%s"
if [ "$(printf '%s' "$SNAP" | wc -l | tr -d ' ')" -gt 30 ]; then ok "-n 输出行数充足 ($(printf '%s' "$SNAP" | wc -l | tr -d ' ') 行)"
else bad "-n 输出行数充足"; fi

chk  "-e 英文界面"         "$SNAP_E" "Memory"
chkn "-e 无中文分区名"     "$SNAP_E" "内存使用"
chk  "-a ASCII 模式"       "$SNAP_A" "##########"
chk  "-n -m 精简模式含网卡" "$SNAP_M" "网卡"
chkn "-n -m 精简模式无进程表" "$SNAP_M" "命令行"
chk  "-n -p 端口映射区标题" "$SNAP_P" "端口 → 进程"
chk  "-n -p 列出监听端口"    "$SNAP_P" "监听"
chk  "紧凑模式(<60列)标记"   "$SNAP_C" "[紧凑]"
chkn "正常宽度无紧凑标记"    "$SNAP" "[紧凑]"
chkn "紧凑模式隐藏磁盘IO行"  "$SNAP_C" "IOPS"

#===============================================================================
head1 '4. 数值正确性 (对照 mock 数据)'
#===============================================================================
# mock net/dev: eth0 rx=1363400000000 tx=424000000000
chk  "累计下行 1.2TB"      "$SNAP" "↓1.2TB"
chk  "累计上行 394.8GB"    "$SNAP" "↑394.8GB"
# mock meminfo: total=16384000kB avail=7500000kB → used 54.2%
chk  "内存使用率 54.2%"    "$SNAP" "54.2%"
# mock: swaptotal=2097152kB swapfree=1680000kB → 19.9%
chk  "Swap 使用率 19.9%"   "$SNAP" "19.9%"
# mock tcp 状态
chk  "TCP 已建立 4"        "$SNAP" "已建立 4"
chk  "TCP SYN_RECV 3"      "$SNAP" "SYN_RECV 3"
chk  "TCP TIME_WAIT 3"     "$SNAP" "TIME_WAIT 3"
chk  "TCP CLOSE_WAIT 2"    "$SNAP" "CLOSE_WAIT 2"
chk  "conntrack 312/65536" "$SNAP" "conntrack 312/65536"
# mock loadavg 1.24 0.98 0.71 3/512 —— 第 4 字段解析
chk  "负载三元组"          "$SNAP" "1.24 0.98 0.71"
chk  "进程 3 / 512 (修正错位)" "$SNAP" "进程 3 / 512"
chk  "负载按核数归一 0.31" "$SNAP" "0.31/核"
# mock df -PT
chk  "磁盘 / 66%"          "$SNAP" "66%"
chk  "磁盘 /data"          "$SNAP" "/data"
chkn "过滤 overlay"        "$SNAP" "overlay"
chkn "过滤 tmpfs/dev-shm"  "$SNAP" "/dev/shm"
# mock df -Pi: 最大 inode 12%
chk  "inode 12%"           "$SNAP" "inode 12%"
# mock thermal 54000
chk  "温度 54°C"           "$SNAP" "54°C"
# mock defunct 进程
chk  "僵尸进程 1"          "$SNAP" "僵尸 1"
# kworker 为 D 状态
chk  "D 状态进程检测"      "$SNAP" "D 状态进程"
# mock 监听端口
chk  "监听端口 22 443"     "$SNAP" "22 443"
# ESTABLISHED 对端 0A00A8C0 → 192.168.0.10
chk  "对端 IP 小端序解码"  "$SNAP" "192.168.0.10"
# cmdline 而非 comm
chk  "进程完整命令行"      "$SNAP" "/usr/bin/node /app/server.js"
# eth0 不得误匹配 eth0.100 (其 rx=999)
chkn "不误配 eth0.100"     "$SNAP" "999B"

#===============================================================================
head1 '5. 导出与状态'
#===============================================================================
chk  "--export 含 cpu_percent" "$EXPORT" "cpu_percent,"
chk  "--export 含 tcp_time_wait" "$EXPORT" "tcp_time_wait,"
chk  "--export 含 quota" "$EXPORT" "quota_percent,"
ncol=$(printf '%s' "$EXPORT" | awk -F, 'NF > 2 { n++ } END { print n+0 }')
chke "--export 每行两列" "$ncol" "0"
chk  "--status 输出运行状态" "$STATUS" "运行状态"
chk  "--status 输出月配额"   "$STATUS" "月配额"
chk  "--status 输出日志目录" "$STATUS" "日志目录"
chk  "--acct status 有输出"  "$ACCT" "流量计数模式"
chk  "--config 显示网卡"     "$CONFIG0" "网卡"
chk  "--config 显示配置文件" "$CONFIG0" "配置文件"

#===============================================================================
head1 '6. 配置命令'
#===============================================================================
Q1=$(h --quota 1024G 2>&1);  RC_Q1=$?
Q2=$(h --quota 500M 2>&1)
Q3=$(h --quota 2T 2>&1)
Q4=$(h --quota 0 2>&1)
QD=$(h --quota 乱写 2>&1); RC_QD=$?
RD=$(h --reset-day 15 2>&1)
RD2=$(h --reset-day 99 2>&1)
KP=$(h --keep 7 2>&1)
IF=$(h --iface eth0 2>&1)
# 重新设定为确定值再读配置 (前面的 Q4/RD2 用例会覆盖)
h --quota 2T >/dev/null 2>&1
h --reset-day 15 >/dev/null 2>&1
CFG=$(h --config 2>&1)
I1=$(h -i 999 2>&1); RC_I1=$?
UK=$(h --不存在的参数 2>&1); RC_UK=$?

chke "--quota 1024G 成功"      "$RC_Q1" "0"
chk  "--quota 1024G 提示"      "$Q1" "月流量配额已设置为"
chk  "--quota 500M"            "$Q2" "500.0MB"
chk  "--quota 2T"              "$Q3" "2.0TB"
chk  "--quota 0 取消限额"      "$Q4" "0B"
if [ "$RC_QD" != "0" ]; then ok "--quota 非法值被拒绝"; else bad "--quota 非法值被拒绝"; fi
chk  "--reset-day 15"          "$RD" "每月 15 日"
chk  "--reset-day 99 收敛到 28" "$RD2" "每月 28 日"
chk  "--keep 7"                "$KP" "已设置为 7 天"
chk  "--iface eth0"            "$IF" "默认网卡已设置为 eth0"
chk  "--config 读到配额"       "$CFG" "2.0TB"
chk  "--config 读到重置日"     "$CFG" "15"
chk  "--config 读到保留天数"   "$CFG" "7 天"
if [ "$RC_I1" != "0" ]; then ok "-i 超范围被拒绝"; else bad "-i 超范围被拒绝"; fi
if [ "$RC_UK" = "1" ]; then ok "未知参数退出码 1"; else bad "未知参数退出码 1" "得到 $RC_UK"; fi
chk  "未知参数有提示"          "$UK" "未知参数"

#===============================================================================
head1 '7. 日志 / 汇总 / 告警 (未启动采集时)'
#===============================================================================
L1=$(h --log 2>&1);     RC_L1=$?
A1=$(h --alert 2>&1);   RC_A1=$?
HI=$(h --history 2>&1); RC_HI=$?
T1=$(h --today 2>&1);   RC_T1=$?
M1=$(h --month 2>&1);   RC_M1=$?
TA=$(h --test-alert 2>&1)
AL=$(h --alert 2>&1)

chke "--log 不挂起"      "$RC_L1" "0"
chke "--alert 不挂起"    "$RC_A1" "0"
chke "--history 不挂起"  "$RC_HI" "0"
chk  "--log 无数据提示"  "$L1" "暂无采集日志"
chk  "--history 无归档提示" "$HI" "暂无历史归档"
chk  "--today 无数据提示" "$T1" "今日暂无采集数据"
chk  "--month 有输出"    "$M1" "本月汇总"
chk  "--test-alert 写日志" "$TA" "已写入告警日志"
chk  "--alert 读到测试告警" "$AL" "这是一条测试告警"

#===============================================================================
head1 '8. 无终端保护'
#===============================================================================
NOARG=$(h 2>&1 < /dev/null); RC_NOARG=$?
if [ "$RC_NOARG" != "0" ]; then ok "无终端时拒绝进入交互面板 (rc=$RC_NOARG)"
else bad "无终端时拒绝进入交互面板" "退出码 0, 可能陷入死循环"; fi
chk "无终端时给出 -n 建议" "$NOARG" "-n"

#===============================================================================
head1 '9. 后台采集 (daemon)'
#===============================================================================
timeout 300 bash "$HTS" --daemon > "$SANDBOX/daemon.out" 2>&1 &
DPID=$!
sleep 20
if kill -0 "$DPID" 2>/dev/null; then ok "daemon 启动并持续运行"
else bad "daemon 启动并持续运行" "$(head -3 "$SANDBOX/daemon.out")"; fi

PIDFILE="$XDG_RUNTIME_DIR/htop-s-$(id -u).pid"
if [ -f "$PIDFILE" ]; then ok "PID 文件已创建"; else bad "PID 文件已创建" "缺少 $PIDFILE"; fi

I2=$(h --daemon 2>&1); RC_I2=$?
if [ "$RC_I2" != "0" ]; then ok "单实例保护生效"; else bad "单实例保护生效" "第二次启动未被拒绝"; fi

sleep 170
# 直接向 daemon 进程发信号 (父进程是 timeout, 信号转发有延迟)
if [ -f "$PIDFILE" ]; then
    DPID2=$(cat "$PIDFILE" 2>/dev/null)
    is_num_case=$(case "${DPID2:-}" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac)
    [ "$is_num_case" = "yes" ] && kill -TERM "$DPID2" 2>/dev/null
fi
kill -TERM "$DPID" 2>/dev/null
for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "$PIDFILE" ] || break
    sleep 3
done
kill -0 "$DPID" 2>/dev/null && kill -9 "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
if [ -f "$PIDFILE" ]; then bad "退出时清理 PID 文件"; else ok "退出时清理 PID 文件"; fi

LOGDIR="$XDG_DATA_HOME/htop-s/log"
CSVF=$(ls -1 "$LOGDIR"/collect-*.csv 2>/dev/null | head -1)
if [ -n "$CSVF" ]; then
    ok "采集日志已生成"
    chk "CSV 表头正确" "$(head -1 "$CSVF")" "时间,epoch,uptime,cpu"
    chke "CSV 共 17 列" "$(head -1 "$CSVF" | awk -F, '{print NF}')" "17"
    nrows=$(wc -l < "$CSVF" | tr -d ' ')
    if [ "$nrows" -ge 3 ]; then ok "已写入 $(( nrows - 1 )) 条采样"
    else bad "至少 2 条采样" "实际 $(( nrows - 1 ))"; fi
    chke "CSV 每行列数一致" "$(awk -F, 'NF != 17 { n++ } END { print n+0 }' "$CSVF")" "0"
    chke "CSV 数值列均为数字" "$(awk -F, 'NR > 1 { for (i = 4; i <= 17; i++) if ($i !~ /^-?[0-9.]+$/) n++ } END { print n+0 }' "$CSVF")" "0"
else
    bad "采集日志已生成" "目录 $LOGDIR 下无 collect-*.csv"
fi

STATE="$XDG_STATE_HOME/htop-s/state"
if [ -f "$STATE" ]; then ok "状态文件已生成"; else bad "状态文件已生成"; fi
chk  "状态文件含计量周期"   "$(cat "$STATE" 2>/dev/null)" "period_start="
chk  "状态文件含告警状态"   "$(cat "$STATE" 2>/dev/null)" "alert_state="
chk  "状态文件含配额"       "$(cat "$STATE" 2>/dev/null)" "quota="
chke "无 .tmp 残留 (原子写)" "$(ls -1 "$XDG_STATE_HOME/htop-s/" 2>/dev/null | grep -c '\.tmp\.' )" "0"

LOG2=$(h --log 2>&1)
chk  "--log 读到真实日志" "$LOG2" "collect-"
TODAY2=$(h --today 2>&1)
chk  "--today 含总流量"   "$TODAY2" "总流量"
chk  "--today 含峰值带宽" "$TODAY2" "峰值带宽"
chk  "--today 含采集时段" "$TODAY2" "采集时段"
MONTH2=$(h --month 2>&1)
chk  "--month 含周期总流量" "$MONTH2" "周期总流量"
STA2=$(h --status 2>&1)
chk  "--status 显示日志文件数" "$STA2" "个文件"

#===============================================================================
head1 '10. 边界与降级 (数据源缺失/畸形)'
#===============================================================================
EMPTY="$SANDBOX/emptyroot"; mkdir -p "$EMPTY"
BADF="$SANDBOX/badproc";   mkdir -p "$BADF/net"

E1=$(HT_S_PROC="$EMPTY" HT_S_ROOT="$EMPTY" HT_S_ETC="$EMPTY" timeout 200 bash "$HTS" -n 2>&1); RC_E1=$?
E2=$(HT_S_PROC="$EMPTY" HT_S_ROOT="$EMPTY" HT_S_ETC="$EMPTY" timeout 200 bash "$HTS" --check 2>&1)

printf 'garbage\n1:2:3\nnot a valid line\n' > "$BADF/net/tcp"
printf 'garbage\n' > "$BADF/loadavg"
printf 'x\n' > "$BADF/stat"
printf 'y\n' > "$BADF/meminfo"
printf 'z\n' > "$BADF/uptime"
printf 'w\n' > "$BADF/vmstat"
printf 'v\n' > "$BADF/net/dev"
printf 'u\n' > "$BADF/net/snmp"
printf 't\n' > "$BADF/net/netstat"
E3=$(HT_S_PROC="$BADF" HT_S_ROOT="$EMPTY" HT_S_ETC="$EMPTY" timeout 200 bash "$HTS" -n 2>&1); RC_E3=$?
E4=$(HT_S_PROC="$BADF" HT_S_ROOT="$EMPTY" HT_S_ETC="$EMPTY" timeout 200 bash "$HTS" --selftest 2>&1)

chk  "全缺失时 --check 报告降级" "$E2" "SKIP"
if [ "$RC_E1" = "0" ] || [ "$RC_E1" = "1" ]; then ok "全缺失时可正常退出 (rc=$RC_E1)"
else bad "全缺失时可正常退出" "rc=$RC_E1"; fi
if has "$E1" "unbound"; then bad "全缺失时无 unbound 错误"; else ok "全缺失时无 unbound 错误"; fi
if [ "$RC_E3" = "0" ] || [ "$RC_E3" = "1" ]; then ok "畸形数据可正常退出 (rc=$RC_E3)"
else bad "畸形数据可正常退出" "rc=$RC_E3"; fi
if has "$E3" "unbound" || has "$E3" "syntax error"; then bad "畸形数据无脚本级错误"; else ok "畸形数据无脚本级错误"; fi
chk "畸形数据下仍输出面板" "$E3" "TCP"

# 非 root 执行 --install
INS=$(h --install 2>&1); RC_INS=$?
if [ "$(id -u)" != "0" ]; then
    if [ "$RC_INS" != "0" ] && has "$INS" "root"; then ok "非 root 执行 --install 被拒绝"
    else bad "非 root 执行 --install 被拒绝" "rc=$RC_INS"; fi
fi

#===============================================================================
head1 '11. 性能'
#===============================================================================
s=$(date +%s%N 2>/dev/null || echo 0)
timeout 240 bash "$HTS" -n >/dev/null 2>&1
e=$(date +%s%N 2>/dev/null || echo 0)
if [ "$s" != "0" ] && [ "$e" != "0" ]; then
    ms=$(( (e - s) / 1000000 ))
    ok "快照全流程 ${ms}ms (含固定 sleep 1s; Windows 沙箱下每次进程启动约 2s)"
else
    printf '  \033[2m[skip]\033[0m 计时不可用\n'
fi

#===============================================================================
printf '\n\033[1m=== 结果 ===\033[0m\n'
printf '  通过: \033[32m%d\033[0m   失败: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '  失败项:%s\n' "$FAILED_LIST"; exit 1; fi
printf '\n\033[32m全部测试通过\033[0m\n'
exit 0
