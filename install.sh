#!/usr/bin/env bash
#===============================================================================
# htop-s 一键安装脚本
#
# 用法:
#   curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash
#   curl -fsSL ... | sudo bash -s -- --service
#   curl -fsSL -x http://127.0.0.1:10808 ... | sudo bash     # 走代理
#
# 选项:
#   -v, --version VER   安装指定版本 (默认: 最新 Release)
#       --prefix DIR    安装目录 (默认: /usr/local/bin)
#       --service       顺带安装并启动开机自启服务
#       --proxy URL     下载走代理 (如 http://127.0.0.1:10808)
#       --no-verify     跳过 sha256 校验
#   -h, --help          显示帮助
#===============================================================================
set -u

REPO_OWNER="zhang123999-qq"
REPO_NAME="htop-s"
PROG="htop-s"

WANT_VER=""
PREFIX="/usr/local/bin"
DO_SERVICE=0
PROXY="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
NO_VERIFY=0

human_size() {
    local n="${1:-0}"
    if   [ "$n" -ge 1048576 ]; then printf '%d.%dMB' $(( n / 1048576 )) $(( (n % 1048576) * 10 / 1048576 ))
    elif [ "$n" -ge 1024 ];    then printf '%d.%dKB' $(( n / 1024 )) $(( (n % 1024) * 10 / 1024 ))
    else printf '%dB' "$n"; fi
}

# 挑选临时目录: 尊重 TMPDIR, 但必须以"实际写入"验证可用; 否则退回标准路径
pick_tmp() {
    local d t
    for d in "${TMPDIR:-}" /tmp /var/tmp .; do
        [ -n "$d" ] || continue
        [ -d "$d" ] || continue
        t="${d%/}/${PROG}.wtest.$$"
        if (umask 077; : > "$t") 2>/dev/null; then
            rm -f "$t" 2>/dev/null
            printf '%s' "${d%/}"
            return 0
        fi
    done
    printf '%s' "."
}

die()  { printf '\033[31m错误: %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m  %s\033[0m\n' "$1"; }

usage() {
    cat <<'EOF'
htop-s 一键安装脚本

用法:
  curl -fsSL <本脚本URL> | sudo bash [选项]
  curl -fsSL <本脚本URL> | sudo bash -s -- --service

选项:
  -v, --version VER   安装指定版本 (默认安装最新 Release)
      --prefix DIR    安装目录 (默认 /usr/local/bin)
      --service       安装后立即启动开机自启服务
      --proxy URL     下载走代理, 例: http://127.0.0.1:10808
      --no-verify     跳过 sha256 校验
  -h, --help          显示本帮助

示例:
  # 最简: 装到 /usr/local/bin
  curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash

  # 装好并开启开机自启
  curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash -s -- --service

  # 指定版本
  curl -fsSL https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash -s -- -v 0.0.5

  # 国内网络走代理
  curl -fsSL -x http://127.0.0.1:10808 https://github.com/zhang123999-qq/htop-s/releases/latest/download/install.sh | sudo bash
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)
            [ $# -ge 2 ] || die "-v 需要一个版本号, 例: -v 0.0.5"
            WANT_VER="${2#v}"; shift 2 ;;
        --version=*) WANT_VER="${1#*=}"; WANT_VER="${WANT_VER#v}"; shift ;;
        --prefix)
            [ $# -ge 2 ] || die "--prefix 需要一个目录"
            PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --service)  DO_SERVICE=1; shift ;;
        --proxy)
            [ $# -ge 2 ] || die "--proxy 需要地址"
            PROXY="$2"; shift 2 ;;
        --proxy=*)  PROXY="${1#*=}"; shift ;;
        --no-verify) NO_VERIFY=1; shift ;;
        -h|--help)  usage ;;
        *) die "未知参数: $1  (用 -h 查看帮助)" ;;
    esac
done

BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}"

printf '\n\033[1mhtop-s 安装程序\033[0m\n\n'

#-------------------------------------------------------------------------------
# 1. 环境检查
#-------------------------------------------------------------------------------
printf '1/5 环境检查\n'
case "$(uname -s 2>/dev/null)" in
    Linux) ;;
    *) die "本程序仅支持 Linux (当前: $(uname -s 2>/dev/null))" ;;
esac
ok "系统: Linux"

if [ -z "${BASH_VERSION:-}" ]; then
    die "请用 bash 运行本脚本"
fi
BV="${BASH_VERSION%%.*}"
if [ "$BV" -lt 3 ] 2>/dev/null; then
    die "需要 bash >= 3.2 (当前 $BASH_VERSION)"
fi
ok "bash: $BASH_VERSION"

if command -v curl >/dev/null 2>&1; then
    DL="curl"
elif command -v wget >/dev/null 2>&1; then
    DL="wget"
else
    die "需要 curl 或 wget 来下载"
fi
ok "下载工具: $DL"

if [ -n "$PROXY" ]; then
    ok "代理: $PROXY"
fi

fetch() {
    # $1=URL $2=输出文件
    if [ "$DL" = "curl" ]; then
        if [ -n "$PROXY" ]; then
            curl -fsSL --connect-timeout 10 --max-time 300 -x "$PROXY" -o "$2" "$1" 2>/dev/null
        else
            curl -fsSL --connect-timeout 10 --max-time 300 -o "$2" "$1" 2>/dev/null
        fi
    else
        if [ -n "$PROXY" ]; then
            http_proxy="$PROXY" https_proxy="$PROXY" wget -q -T 30 -O "$2" "$1" 2>/dev/null
        else
            wget -q -T 30 -O "$2" "$1" 2>/dev/null
        fi
    fi
}

#-------------------------------------------------------------------------------
# 2. 权限与目录
#-------------------------------------------------------------------------------
printf '\n2/5 准备安装目录\n'
mkdir -p "$PREFIX" 2>/dev/null || die "无法创建目录 $PREFIX (可能需要 sudo)"
[ -w "$PREFIX" ] || die "目录 $PREFIX 不可写 (请用 sudo 运行)"
TARGET="$PREFIX/$PROG"
ok "安装到: $TARGET"
if [ -f "$TARGET" ]; then
    info "检测到已安装版本, 将被覆盖"
fi

#-------------------------------------------------------------------------------
# 3. 下载
#-------------------------------------------------------------------------------
printf '\n3/5 下载程序\n'
TMP="$(pick_tmp)/${PROG}.install.$$"
if [ -n "$WANT_VER" ]; then
    URL="$BASE/releases/download/v${WANT_VER}/${PROG}"
    info "版本: v$WANT_VER (指定)"
else
    URL="$BASE/releases/latest/download/${PROG}"
    info "版本: 最新 Release"
fi
info "$URL"
if ! fetch "$URL" "$TMP"; then
    rm -f "$TMP" 2>/dev/null
    if [ -n "$PROXY" ]; then
        die "下载失败 (检查网络或代理是否可用: $PROXY)"
    else
        die "下载失败 (若在受限网络, 尝试加 --proxy http://127.0.0.1:10808)"
    fi
fi
SIZE=$(wc -c < "$TMP" 2>/dev/null | tr -d ' ')
[ -n "$SIZE" ] && [ "$SIZE" -gt 10240 ] || { rm -f "$TMP"; die "下载文件异常 (仅 $SIZE 字节)"; }
ok "已下载 $(human_size "$SIZE")"


#-------------------------------------------------------------------------------
# 4. 校验
#-------------------------------------------------------------------------------
printf '\n4/5 校验\n'
if ! bash -n "$TMP" 2>/dev/null; then
    rm -f "$TMP" 2>/dev/null
    die "下载内容不是有效的 shell 脚本, 已中止"
fi
ok "语法校验通过"

GOT_VER=$(awk -F'"' '/^VERSION=/{print $2; exit}' "$TMP" 2>/dev/null)
[ -n "$GOT_VER" ] || { rm -f "$TMP" 2>/dev/null; die "文件缺少 VERSION 声明"; }
if [ -n "$WANT_VER" ] && [ "$GOT_VER" != "$WANT_VER" ]; then
    rm -f "$TMP" 2>/dev/null
    die "版本不符: 期望 $WANT_VER, 实际 $GOT_VER"
fi
ok "版本: v$GOT_VER"

if [ "$NO_VERIFY" != "1" ] && command -v sha256sum >/dev/null 2>&1; then
    SUMPROG="$(pick_tmp)/${PROG}.sum.$$"
    SUMURL="${URL}.sha256"
    if fetch "$SUMURL" "$SUMPROG" && [ -s "$SUMPROG" ]; then
        WANT_SUM=$(awk '{print $1}' "$SUMPROG" 2>/dev/null | head -1)
        GOT_SUM=$(sha256sum "$TMP" 2>/dev/null | awk '{print $1}')
        if [ -n "$WANT_SUM" ] && [ "$WANT_SUM" = "$GOT_SUM" ]; then
            ok "sha256 校验通过"
        else
            rm -f "$TMP" "$SUMPROG" 2>/dev/null
            die "sha256 校验失败 (可能下载损坏或被人篡改)"
        fi
    else
        info "未找到校验和文件, 跳过 sha256 (可加 --no-verify 消除本提示)"
    fi
    rm -f "$SUMPROG" 2>/dev/null
fi

#-------------------------------------------------------------------------------
# 5. 安装
#-------------------------------------------------------------------------------
printf '\n5/5 安装\n'
if [ -f "$TARGET" ]; then
    cp "$TARGET" "$TARGET.bak" 2>/dev/null && info "旧版已备份: $TARGET.bak"
fi
cp "$TMP" "$TARGET" 2>/dev/null || { rm -f "$TMP"; die "写入 $TARGET 失败"; }
chmod 755 "$TARGET" 2>/dev/null
rm -f "$TMP" 2>/dev/null
ok "已安装: $TARGET"

if [ "$DO_SERVICE" = "1" ]; then
    printf '\n'
    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        printf '\033[33m  跳过服务安装: 需要 root\033[0m\n'
    elif ! command -v systemctl >/dev/null 2>&1; then
        printf '\033[33m  跳过服务安装: 本机没有 systemd\033[0m\n'
        printf '  可手动后台运行: nohup %s --daemon >/dev/null 2>&1 &\n' "$TARGET"
    else
        "$TARGET" --install
    fi
fi

printf '\n\033[32m\033[1m安装完成\033[0m\n\n'
printf '  启动面板     %s\n' "$PROG"
printf '  环境自检     %s --check\n' "$PROG"
printf '  查看版本     %s -V\n' "$PROG"
printf '  设置配额     %s --quota 1024G\n' "$PROG"
printf '  检查更新     %s --check-update\n' "$PROG"
printf '  在线更新     sudo %s --update\n' "$PROG"
printf '  卸载         sudo %s --uninstall\n' "$PROG"
if [ "$DO_SERVICE" != "1" ]; then
    printf '\n  想让服务器开机自动监控:  sudo %s --install\n' "$PROG"
fi
if [ "$PREFIX" != "/usr/local/bin" ]; then
    printf '\n  \033[33m注意: 安装到了 %s, 请确认它在 PATH 中\033[0m\n' "$PREFIX"
fi
printf '\n'
