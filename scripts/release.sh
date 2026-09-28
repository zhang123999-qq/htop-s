#!/usr/bin/env bash
# scripts/release.sh — htop-s 发布脚本
#
# 把"打 tag → 建 Release → 传附件"锁成固定流程，防住一个真实踩过的坑：
#   已发布的 tag 绝不能直接删/移动 —— 删远程 tag 会让 GitHub Release
#   变成孤儿 draft（附件 URL 全变 untagged-...，latest/download 还可能走
#   CDN 缓存给旧文件）。正确顺序：先删 Release，再动 tag。
#
# 用法:
#   scripts/release.sh v0.0.8 [-m "release notes" | -F notes.md] [--force-retag] [--no-verify]
#
# 预期: 在仓库根目录运行；发布前请先把 release 提交做好并推到 origin/main，
# 本脚本只负责 tag + Release + 附件（坑就藏在这段）。

set -u

PROG="htop-s"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

die()  { printf '\033[31m错误: %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m  %s\033[0m\n' "$1"; }

usage() {
    cat <<'EOF'
htop-s 发布脚本：打 tag → 建 GitHub Release → 上传附件 → 验证下载链

用法: scripts/release.sh vX.Y.Z [-m "notes" | -F notes.md] [--force-retag] [--no-verify]

  -m TEXT        Release 说明文字
  -F FILE        从文件读 Release 说明（默认用提交历史自动生成）
  --force-retag  远程 tag 已指向别的提交时，仍强制重打。
                 按正确顺序执行：先删 Release → 再删远程 tag → 重打 tag → 重建 Release。
                 没有此旗标时直接拒绝，避免 Release 变孤儿。
  --no-verify    跳过 bash -n / --selftest（不推荐）
  -h             显示帮助
EOF
}

TAG=""; NOTES=""; NOTES_FILE=""; FORCE_RETAG=0; VERIFY=1
while [ $# -gt 0 ]; do
    case "$1" in
        -m) NOTES="${2:?缺 -m 参数}"; shift 2 ;;
        -F) NOTES_FILE="${2:?缺 -F 参数}"; shift 2 ;;
        --force-retag) FORCE_RETAG=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        -h|--help) usage; exit 0 ;;
        v*) [ -z "$TAG" ] || die "只能指定一个版本号"; TAG="$1"; shift ;;
        *) die "未知参数: $1（用 -h 查看用法）" ;;
    esac
done
[ -n "$TAG" ] || { usage; die "请指定版本号，如 v0.0.8"; }

#---------------------------------------------------------------- 1. 环境与版本
command -v git >/dev/null || die "缺 git"
command -v gh >/dev/null || die "缺 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未登录"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 vX.Y.Z，实得: $TAG"
VER="${TAG#v}"
file_ver="$(grep -m1 '^VERSION=' "$PROG" 2>/dev/null | cut -d'"' -f2)"
[ "$file_ver" = "$VER" ] || die "$PROG 内 VERSION=$file_ver，与 $TAG 不一致"
[ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$REPO_DIR" ] || die "不在仓库根目录"
[ "$(git branch --show-current)" = "main" ] || die "请在 main 分支发布"
git diff --quiet && git diff --cached --quiet || die "工作树不干净，先提交"
git fetch origin --tags 2>/dev/null || die "git fetch origin 失败"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "本地 main 与 origin/main 不一致，先同步"

#---------------------------------------------------------------- 2. 自检
if [ "$VERIFY" = "1" ]; then
    info "语法检查…"
    bash -n "$PROG" || die "bash -n 未通过"
    info "自测…"
    bash "$PROG" --selftest 2>&1 | grep -q "全部通过" || die "--selftest 未全部通过"
    ok "自检通过"
fi

#---------------------------------------------------------------- 3. tag 状态机（坑在这里）
# 注意: annotated tag 在 ls-remote 里默认只给 tag 对象 SHA，必须显式要 ^{}
# 才拿到它指向的 commit；取不到（如 lightweight tag）再回退到普通查询
remote_sha="$(git ls-remote origin "refs/tags/$TAG^{}" 2>/dev/null | awk '{print $1}')"
[ -z "$remote_sha" ] && \
    remote_sha="$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null | awk '{print $1}')"
if [ -n "$remote_sha" ]; then
    # 远程 tag 已存在：看它指哪儿
    if [ "$remote_sha" = "$(git rev-parse HEAD)" ]; then
        info "远程 tag $TAG 已指向当前 HEAD，跳过打 tag"
    else
        # tag 指向别的提交 —— 先查 GitHub 上有没有已发布的 Release
        rel_state="$(gh release view "$TAG" --json isDraft 2>/dev/null \
            | grep -o '"isDraft":[a-z]*' | cut -d: -f2 || true)"
        if [ "$rel_state" = "false" ]; then
            [ "$FORCE_RETAG" = "1" ] || die \
"远程 tag $TAG 已指向 $remote_sha，且 GitHub 上有已发布的 Release。
直接删/移动 tag 会让 Release 变孤儿 draft（附件 URL 全变 untagged-...）。
如确认要重打，加 --force-retag（脚本会先删 Release 再动 tag）。"
            info "--force-retag：按正确顺序重打（先删 Release，再删 tag）"
            gh release delete "$TAG" --yes >/dev/null \
                || die "删除 GitHub Release 失败"
            ok "已删 GitHub Release $TAG"
        elif [ "$rel_state" = "true" ]; then
            info "GitHub 上是 draft Release，一并删掉重建"
            gh release delete "$TAG" --yes >/dev/null 2>&1 || true
        else
            info "GitHub 上无 Release，直接重打 tag"
        fi
        git push origin ":refs/tags/$TAG" >/dev/null 2>&1 \
            || die "删除远程 tag 失败"
        git tag -d "$TAG" >/dev/null 2>&1 || true
        ok "已删旧 tag $TAG"
        remote_sha=""
    fi
fi
if [ -z "$remote_sha" ]; then
    git tag -a "$TAG" -m "$PROG $VER" || die "建 tag 失败"
    git push origin "$TAG" || die "push tag 失败"
    ok "tag $TAG 已推送"
fi

#---------------------------------------------------------------- 4. Release 说明
if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || die "说明文件不存在: $NOTES_FILE"
    notes_file="$NOTES_FILE"
elif [ -n "$NOTES" ]; then
    notes_file="$(mktemp)"
    printf '%s\n' "$NOTES" > "$notes_file"
else
    prev_tag="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
    notes_file="$(mktemp)"
    {
        printf '## 改动\n\n'
        if [ -n "$prev_tag" ]; then
            git log "${prev_tag}..HEAD" --format='- %s' --reverse
        else
            git log --format='- %s' --reverse -5
        fi
    } > "$notes_file"
fi
[ -s "$notes_file" ] || die "Release 说明为空"

#---------------------------------------------------------------- 5. 建 Release + 传附件
if gh release view "$TAG" --json isDraft 2>/dev/null | grep -q '"isDraft":false'; then
    info "Release $TAG 已发布，补传附件"
else
    gh release create "$TAG" --title "$TAG" --notes-file "$notes_file" \
        || die "建 Release 失败"
    ok "Release $TAG 已创建"
fi
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd" "$notes_file"' EXIT
( cd "$tmpd" && sha256sum "$REPO_DIR/$PROG" > "$PROG.sha256" )
gh release upload "$TAG" "$REPO_DIR/$PROG" "$tmpd/$PROG.sha256" "$REPO_DIR/install.sh" \
    --clobber || die "上传附件失败"
ok "附件已上传: $PROG / $PROG.sha256 / install.sh"

#---------------------------------------------------------------- 6. 验证下载链
info "验证下载链…"
vd="$tmpd/verify"; mkdir -p "$vd"
for f in "$PROG" "$PROG.sha256" install.sh; do
    curl -fsSL -o "$vd/$f" "https://github.com/zhang123999-qq/htop-s/releases/download/$TAG/$f" \
        || die "下载失败: $f"
done
( cd "$vd" && sha256sum -c "$PROG.sha256" >/dev/null ) || die "sha256 校验失败"
bash -n "$vd/$PROG" || die "下载文件的语法检查失败"
got_ver="$(bash "$vd/$PROG" --version 2>/dev/null | awk '{print $2}')"
[ "$got_ver" = "$VER" ] || die "下载文件版本 $got_ver 与 $TAG 不一致"
ok "下载链验证通过（版本 $got_ver，sha256 一致）"
printf '\n发布完成: https://github.com/zhang123999-qq/htop-s/releases/tag/%s\n' "$TAG"
