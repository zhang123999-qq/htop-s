#!/usr/bin/env bash
# 构造 mock /proc /sys /etc 环境, 用于在非 Linux 主机上验证 htop-s 的解析逻辑
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
M="$ROOT/mock"
rm -rf "$M"
mkdir -p "$M/proc/net/sys/net/netfilter" "$M/proc/sys/net/netfilter" "$M/sys/class/net/eth0" \
         "$M/sys/class/thermal/thermal_zone0" "$M/sys/block/sda" "$M/sys/block/dm-0" \
         "$M/sys/block/loop0" "$M/etc" "$M/bin"

P="$M/proc"

cat > "$P/stat" <<'EOF'
cpu  100000 500 50000 900000 10000 20 5000 200 0 0
cpu0 25000 125 12500 225000 2500 5 1250 50 0 0
cpu1 25000 125 12500 225000 2500 5 1250 50 0 0
cpu2 25000 125 12500 225000 2500 5 1250 50 0 0
cpu3 25000 125 12500 225000 2500 5 1250 50 0 0
intr 1234567
ctxt 2345678
btime 1757000000
processes 12345
procs_running 3
procs_blocked 1
softirq 999999
EOF

printf '363723.45 1234567.89\n' > "$P/uptime"
printf '1.24 0.98 0.71 3/512 12345\n' > "$P/loadavg"

cat > "$P/meminfo" <<'EOF'
MemTotal:       16384000 kB
MemFree:         1234567 kB
MemAvailable:    7500000 kB
Buffers:          123456 kB
Cached:          3200000 kB
SwapCached:            0 kB
SReclaimable:     200000 kB
Shmem:             50000 kB
Dirty:             12000 kB
Writeback:             0 kB
SwapTotal:       2097152 kB
SwapFree:        1680000 kB
EOF

cat > "$P/vmstat" <<'EOF'
nr_free_pages 123456
pgpgin 9876543
pgpgout 1234567
pswpin 100
pswpout 250
oom_kill 0
nr_dirty 30
EOF

cat > "$P/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000000    5000    0    0    0     0          0         0  1000000    5000    0    0    0     0       0          0
  eth0: 1363400000000 900000000 3 7 0 0 0 0 424000000000 300000000 2 5 0 0 0 0
eth0.100: 999 10 0 0 0 0 0 0 111 10 0 0 0 0 0 0
EOF

cat > "$P/net/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 11111 1 0000:000000 100 0 0 10 0
   1: 00000000:01BB 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 22222 1 0000:000000 100 0 0 10 0
   2: 0100007F:1F90 0A00A8C0:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 33333 1 0000:000000 100 0 0 10 0
   3: 0100007F:1F90 0A00A8C0:01BC 01 00000000:00000000 00:00000000 00000000  1000        0 33334 1 0000:000000 100 0 0 10 0
   4: 0100007F:1F90 CB0071C6:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 33335 1 0000:000000 100 0 0 10 0
   5: 0100007F:1F90 0A00A8C0:01BD 06 00000000:00000000 00:00000000 00000000  1000        0 33336 1 0000:000000 100 0 0 10 0
   6: 0100007F:1F90 0A00A8C0:01BE 06 00000000:00000000 00:00000000 00000000  1000        0 33337 1 0000:000000 100 0 0 10 0
   7: 0100007F:1F90 0A00A8C0:01BF 06 00000000:00000000 00:00000000 00000000  1000        0 33338 1 0000:000000 100 0 0 10 0
   8: 0100007F:1F90 0A00A8C0:01C0 08 00000000:00000000 00:00000000 00000000  1000        0 33339 1 0000:000000 100 0 0 10 0
   9: 0100007F:1F90 0A00A8C0:01C1 08 00000000:00000000 00:00000000 00000000  1000        0 33340 1 0000:000000 100 0 0 10 0
  10: 0100007F:1F90 0A00A8C1:01C2 03 00000000:00000000 00:00000000 00000000  1000        0 33341 1 0000:000000 100 0 0 10 0
  11: 0100007F:1F90 0A00A8C1:01C3 03 00000000:00000000 00:00000000 00000000  1000        0 33342 1 0000:000000 100 0 0 10 0
  12: 0100007F:1F90 0A00A8C1:01C4 03 00000000:00000000 00:00000000 00000000  1000        0 33343 1 0000:000000 100 0 0 10 0
  13: 0100007F:1F90 0A00A8C1:01C5 02 00000000:00000000 00:00000000 00000000  1000        0 33344 1 0000:000000 100 0 0 10 0
EOF

cat > "$P/net/tcp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 44444 1 0000:000000 100 0 0 10 0
   1: 00000000000000000000000001000000:1F91 00000000000000000000000001000000:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 44445 1 0000:000000 100 0 0 10 0
EOF

cat > "$P/net/udp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
   0: 00000000:0035 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 55555 2 0000000000000000 0
   1: 00000000:007B 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 55556 2 0000000000000000 0
EOF

cat > "$P/net/udp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
   0: 00000000000000000000000000000000:0035 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 55557 2 0000000000000000 0
EOF

cat > "$P/net/snmp" <<'EOF'
Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates
Ip: 1 64 12345678 0 0 0 0 0 12345678 12000000 0 0 0 0 0 0 0 0 0
Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps
Icmp: 100 0 0 10 0 0 0 0 90 0 0 0 0 0 100 0 10 0 0 0 0 90 0 0 0 0 0
Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 5000 3000 12 30 46 1234567 2345678 8900 0 120 0
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti
Udp: 98765 12 0 98700 0 0 0 0
EOF

cat > "$P/net/netstat" <<'EOF'
TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts PruneCalled RcvPruned OfoPruned OutOfWindowIcmps LockDroppedIcmps ArpFilter TW TWRecycled TWKilled PAWSPassive PAWSActive PAWSEstab DelayedACKs DelayedACKLocked DelayedACKLost ListenOverflows ListenDrops TCPHPHits TCPPureAcks TCPHPAcks TCPRenoRecovery TCPSackRecovery TCPSACKReneging TCPSACKReorder TCPRenoReorder TCPTSReorder TCPFullUndo TCPPartialUndo TCPDSACKUndo TCPLossUndo TCPLostRetransmit TCPRenoFailures TCPSackFailures TCPLossFailures TCPFastRetrans TCPSlowStartRetrans TCPTimeouts TCPLossProbes TCPLossProbeRecovery TCPRenoRecoveryFail TCPSackRecoveryFail TCPRcvCollapsed TCPDSACKOldSent TCPDSACKOfoSent TCPDSACKRecv TCPDSACKOfoRecv TCPAbortOnData TCPAbortOnClose TCPAbortOnMemory TCPAbortOnTimeout TCPAbortOnLinger TCPAbortFailed TCPMemoryPressures TCPSACKDiscard TCPDSACKIgnoredOld TCPDSACKIgnoredNoUndo TCPSpuriousRTOs TCPMD5NotFound TCPMD5Unexpected TCPSackShifted TCPSackMerged TCPSackShiftFallback TCPBacklogDrop TCPMinTTLDrop TCPDeferAcceptDrop IPReversePathFilter TCPTimeWaitOverflow TCPReqQFullDoCookies TCPReqQFullDrop TCPRetransFail TCPRcvCoalesce TCPOFOQueue TCPOFODrop TCPOFOMerge TCPChallengeACK TCPSYNChallenge TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPSynRetrans TCPOrigDataSent TCPHystartTrainDetect
TcpExt: 0 0 0 0 0 0 0 0 0 0 152 0 0 0 0 0 12345 0 0 0 0 999 100 50 0 12 0 0 0 0 0 0 0 0 3 0 2 1 45 12 120 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1234
EOF

printf '312\n' > "$P/sys/net/netfilter/nf_conntrack_count"
printf '65536\n' > "$P/sys/net/netfilter/nf_conntrack_max"

cat > "$P/diskstats" <<'EOF'
   8       0 sda 100000 2000 5000000 30000 50000 1000 2000000 40000 0 60000 70000
   8       1 sda1 90000 1900 4800000 29000 49000 990 1900000 39000 0 58000 68000
 253       0 dm-0 80000 1800 4500000 28000 48000 980 1800000 38000 0 56000 66000
   7       0 loop0 0 0 0 0 0 0 0 0 0 0 0
EOF

printf 'ID="debian"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nVERSION_ID="12"\n' > "$M/etc/os-release"
printf 'up\n' > "$M/sys/class/net/eth0/operstate"
printf '54000\n' > "$M/sys/class/thermal/thermal_zone0/temp"
printf '1\n' > "$M/sys/block/sda/dev"
printf '1\n' > "$M/sys/block/dm-0/dev"
printf '1\n' > "$M/sys/block/loop0/dev"

# --- 进程 ---
mkproc() {
    local pid="$1" comm="$2" st="$3" ut="$4" stime="$5" thr="$6" rss="$7" starttime="$8" cmdline="$9"
    local d="$P/$pid"
    mkdir -p "$d"
    printf '%s (%s) %s 0 1 1 0 -1 4194560 12345 0 12 0 %s %s 0 0 20 0 %s 0 %s 12345678 %s 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' \
        "$pid" "$comm" "$st" "$ut" "$stime" "$thr" "$starttime" "$rss" > "$d/stat"
    printf '%s\n' "$comm" > "$d/comm"
    if [ -n "$cmdline" ]; then
        printf '%s\0' $cmdline > "$d/cmdline"
    else
        : > "$d/cmdline"
    fi
    mkdir -p "$d/fd"
}

mkproc 1    systemd           S 800  400  1  12000  100    "/sbin/init"
mkproc 102  sshd              S 120  60   1  4000   300    "/usr/sbin/sshd -D"
mkproc 331  nginx             S 300  200  2  2200   500    "/usr/sbin/nginx -g daemon off;"
mkproc 902  kworker           D 0    0    1  8800   700    ""
mkproc 1204 postgres          S 900  300  4  3100   900    "/usr/lib/postgresql/15/bin/postgres"
mkproc 8821 node              R 3800 1200 16 12400  1100   "/usr/bin/node /app/server.js"
mkproc 9001 containerd-shim   S 500  400  6  5600   1200   "/usr/bin/containerd-shim-runc-v2"
mkproc 9102 redis-server      S 700  100  4  2400   1300   "/usr/bin/redis-server 0.0.0.0:6379"
mkproc 9203 dockerd           S 400  900  20 9000   1400   "/usr/bin/dockerd -H fd://"
mkproc 9304 cron              S 10   10   1  800    1500   "/usr/sbin/cron -f"
mkproc 9405 mysqld            S 300  200  28 15000  1600   "/usr/sbin/mysqld"
mkproc 9506 php-fpm           S 200  100  1  3300   1700   "/usr/sbin/php-fpm --nodaemonize"
mkproc 9607 tailscaled        S 600  300  14 6600   1800   "/usr/sbin/tailscaled"
mkproc 9708 bash              S 5    5    1  500    1900   "/bin/bash"
mkproc 9809 python3           S 100  50   4  4200   2000   "/usr/bin/python3 /opt/agent/run.py"
mkproc 9900 defunct           Z 0    0    1  0      2100   ""

# --- df 桩 ---
cat > "$M/bin/df" <<'DFEOF'
#!/usr/bin/env bash
case "$*" in
    *-Pi*|*-iP*)
        cat <<'X'
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/sda1      3276800 393216 2883584   12% /
/dev/sdb1     52428800 1048576 51380224    2% /data
tmpfs           2048000       1 2047999    1% /dev/shm
X
        ;;
    *)
        cat <<'X'
Filesystem     Type 1024-blocks      Used Available Capacity Mounted on
/dev/sda1      ext4   51475068  32000000  17000000      66% /
/dev/sdb1      xfs   104857600  20971520  83886080      21% /data
tmpfs         tmpfs   8192000         0   8192000       0% /dev/shm
overlay       overlay 26214400  10000000  16214400      39% /var/lib/docker/overlay2/x
X
        ;;
esac
DFEOF
chmod +x "$M/bin/df"

echo "mock 环境已生成: $M"
