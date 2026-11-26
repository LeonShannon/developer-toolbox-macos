#!/bin/bash
set -euo pipefail
umask 077

# Antigravity 版本更新与授权补丁
# 依赖外部补丁器（GPL-3.0，独立进程调用，不并入本仓库）
# 补丁器路径读自同目录 antigravity.local.sh，也可用环境变量 TOOLBOX_ANTIGRAVITY_PATCHER 覆盖

app=/Applications/Antigravity.app
plist="$app/Contents/Info.plist"
store="$HOME/Library/Application Support/开发工具箱/Antigravity"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
page=https://antigravity.google/download
arch=darwin-arm
[[ "$(/usr/bin/uname -m)" == x86_64 ]] && arch=darwin-x64

fail() { printf '停止：%s\n' "$*" >&2; exit 1; }
version_at() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
fetch() {
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' \
        --proto-redir '=https' --connect-timeout 10 --max-time ${3:-600} "$1" -o "$2"
}

# ---------- 补丁器定位 ----------
patcher="${TOOLBOX_ANTIGRAVITY_PATCHER:-}"
if [[ -z "$patcher" && -f "$here/antigravity.local.sh" ]]; then
    # shellcheck disable=SC1091
    . "$here/antigravity.local.sh"
    patcher="${TOOLBOX_ANTIGRAVITY_PATCHER:-}"
fi
patcher="${patcher/#\~\//$HOME}"
python="$patcher/.venv/bin/python"

# ---------- 环境校验 ----------
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail '此功能仅支持 macOS。'
[[ -d "$app" ]] || fail '未找到 /Applications/Antigravity.app，请先安装官方客户端。'
[[ -n "$patcher" ]] || fail "尚未配置授权补丁器路径。
请按 README 创建 antigravity.local.sh（可复制 antigravity.example.sh），
填入 open-antigravity-patcher 的 source 目录。"
[[ -x "$python" ]] || fail "未找到补丁器环境：$python
请确认 antigravity.local.sh 指向的目录包含可用的 .venv。"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" == com.google.antigravity ]] ||
    fail '无法确认客户端身份。'

current=$(version_at "$app") || fail '无法读取客户端版本。'
printf '本机 Antigravity：%s\n' "$current"

# ---------- 查询官方最新版 ----------
printf '正在查询官方最新版本…\n'
latest_url=$(/usr/bin/curl --fail --silent --show-error --location --proto '=https' --max-time 30 \
    -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0 Safari/537.36' "$page" |
    /usr/bin/grep -o -E "https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/${arch}/Antigravity\.dmg" |
    /usr/bin/sort -u -V | /usr/bin/tail -1) || fail '无法访问官方下载页，请检查网络。'
[[ -n "$latest_url" ]] || fail '未能从官方页面解析出安装包地址（页面结构可能已变更）。'
latest=$(printf '%s' "$latest_url" | /usr/bin/sed -E 's#.*/antigravity-hub/([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+/.*#\1#')
[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '未能解析出官方版本号（页面结构可能已变更）。'
printf '官方最新版本：%s\n' "$latest"

# ---------- 补丁状态 ----------
patch_state() {
    "$python" - "$patcher" <<'PY' 2>/dev/null || printf '未知'
import sys
sys.path.insert(0, sys.argv[1])
from patcher.manager.discovery import find_manager_binary
from patcher.manager.patcher import MANAGER_GATE
p = find_manager_binary()
if not p:
    print('未找到目标'); raise SystemExit
try:
    kind, _, gate = MANAGER_GATE.resolve(open(p, 'rb').read())
    print('已打补丁' if kind == 'patched' else '未打补丁')
except LookupError:
    print('特征码不匹配')
PY
}
current_state=$(patch_state)
printf '当前补丁状态：%s\n' "$current_state"

case "${1:-}" in
    --check) exit 0 ;;
    --update) ;;
    *) fail '请从开发工具箱选择「检查更新」或「更新并打补丁」。' ;;
esac

need_replace=1
if [[ "$current" == "$latest" ]]; then
    need_replace=0
    if [[ "$current_state" == 已打补丁 ]]; then
        printf '已是最新版本且补丁有效，无需操作。\n'
        exit 0
    fi
    printf '当前已是最新版本，将只重新打补丁。\n'
fi

/bin/mkdir -p "$store"
lock="$store/.lock"
mount_point=
lock_owned=0
cleanup() {
    [[ -z "$mount_point" ]] || /usr/bin/hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    [[ $lock_owned -eq 0 ]] || /bin/rm -rf "$lock" 2>/dev/null || true
}
# 中断时先清理再退出，避免锁被移除后继续执行替换
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# 任务锁：仅在持有进程仍存活时视为占用，异常退出留下的陈旧锁自动回收
if ! /bin/mkdir "$lock" 2>/dev/null; then
    holder=$(/bin/cat "$lock/pid" 2>/dev/null || true)
    if [[ -n "$holder" ]] && /bin/kill -0 "$holder" 2>/dev/null; then
        fail "已有任务正在运行（PID $holder），请等待其结束后重试。"
    fi
    /bin/rm -rf "$lock"
    /bin/mkdir "$lock" 2>/dev/null || fail "无法创建任务锁：$lock"
fi
lock_owned=1
printf '%s\n' $$ > "$lock/pid"

# ---------- 下载与预检 ----------
if [[ $need_replace -eq 1 ]]; then
    dmg="$store/Antigravity-$latest.dmg"
    if [[ -f "$dmg" ]]; then
        printf '使用已缓存的安装包。\n'
    else
        printf '正在下载安装包（约 231 MB）…\n'
        fetch "$latest_url" "$dmg" 900 || fail '安装包下载失败。'
    fi
    printf '正在校验磁盘映像…\n'
    /usr/bin/hdiutil verify "$dmg" >/dev/null 2>&1 || { /bin/rm -f "$dmg"; fail '安装包校验失败，已删除。'; }

    mount_point=$(/usr/bin/hdiutil attach -nobrowse -readonly "$dmg" 2>/dev/null |
        /usr/bin/grep -o '/Volumes/.*' | /usr/bin/tail -1) || fail '无法挂载安装包。'
    new_app="$mount_point/Antigravity.app"
    [[ -d "$new_app" ]] || fail '安装包内未找到 Antigravity.app。'

    new_version=$(version_at "$new_app") || fail '无法读取新版版本号。'
    [[ "$new_version" == "$latest" ]] || fail "安装包版本 $new_version 与预期 $latest 不符。"

    # 官方签名校验：确保安装包未被篡改
    /usr/bin/codesign --verify --strict \
        -R='anchor apple generic and identifier "com.google.antigravity" and certificate leaf[subject.OU] = "EQHXZ8M8AV"' \
        "$new_app" 2>/dev/null || fail '新版签名校验未通过，已中止。'
    printf '新版签名验证通过（Google 官方）。\n'

    # 补丁兼容性预检：签名若失效则特征码可能同时失效
    printf '正在预检补丁兼容性…\n'
    "$python" - "$patcher" "$new_app" <<'PY' || fail '新版尚未被补丁器支持，已中止（系统未做任何改动）。'
import sys
sys.path.insert(0, sys.argv[1])
from patcher.manager.patcher import MANAGER_GATE
target = sys.argv[2] + '/Contents/Resources/bin/language_server'
MANAGER_GATE.resolve(open(target, 'rb').read())
PY
    printf '补丁兼容性预检通过。\n'
fi

# ---------- 用户确认 ----------
printf '\n即将执行：\n'
[[ $need_replace -eq 1 ]] && printf '  · 替换客户端 %s → %s\n' "$current" "$latest"
printf '  · 重新应用授权补丁（会使客户端签名变为 ad-hoc）\n'
printf '  · 完成后客户端将无法使用内置自动更新，后续请使用本功能升级\n'
printf '\n等待确认更新客户端\n'
if ! read -r confirmation || [[ "$confirmation" != 确认更新 ]]; then
    printf '\n已取消，未做任何改动。\n'
    exit 0
fi

# ---------- 退出客户端 ----------
pattern='^/Applications/Antigravity[.]app/Contents/MacOS/Antigravity( |$)'
if /usr/bin/pgrep -f "$pattern" >/dev/null; then
    printf '正在退出 Antigravity…\n'
    /usr/bin/pkill -TERM -f "$pattern" 2>/dev/null || true
    for ((i = 0; i < 15; i++)); do
        /usr/bin/pgrep -f "$pattern" >/dev/null || break
        /bin/sleep 1
    done
    /usr/bin/pgrep -f "$pattern" >/dev/null && fail '客户端仍在运行，已停止。请手动退出后重试。'
fi

# ---------- 替换 ----------
if [[ $need_replace -eq 1 ]]; then
    # 先在 /Applications 内复制新版本并校验，校验通过才动原版本，缩窄破坏窗口
    staging=/Applications/.Antigravity.app.new
    previous="$store/上一版本-$current"
    /bin/rm -rf "$staging"
    printf '正在替换客户端…\n'
    if ! /usr/bin/ditto "$new_app" "$staging"; then
        /bin/rm -rf "$staging"
        fail '复制新版失败，原版本未受影响。'
    fi
    if [[ "$(version_at "$staging")" != "$latest" ]]; then
        /bin/rm -rf "$staging"
        fail '复制后版本校验失败，原版本未受影响。'
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$staging" 2>/dev/null || true

    /bin/rm -rf "$previous" 2>/dev/null || true
    if ! /bin/mv "$app" "$previous"; then
        if [[ -d "$app" ]]; then
            /bin/rm -rf "$staging"
            fail '无法移动旧版本（/Applications 不可写），原版本未受影响。'
        fi
        # 旧版本已被部分移走：改用已校验的新版本就位，避免留下不完整安装
        /bin/mv "$staging" "$app" || fail "旧版本移动失败且新版本无法就位，请重新安装官方客户端（旧版本残留于 $previous）。"
        printf '警告：旧版本未能完整移出，已直接使用新版安装。\n' >&2
    elif ! /bin/mv "$staging" "$app"; then
        /bin/mv "$previous" "$app" 2>/dev/null || true
        fail '安装新版失败，已回滚到原版本。'
    fi
    # 替换后属主变为当前用户，后续写入无需提权
    if [[ "$(version_at "$app")" != "$latest" ]]; then
        /bin/rm -rf "$app"
        /bin/mv "$previous" "$app" 2>/dev/null || true
        fail '替换后版本校验失败，已回滚。'
    fi
    printf '已更新到 %s（旧版本保留于 %s）。\n' "$latest" "$previous"
    [[ -z "$mount_point" ]] || { /usr/bin/hdiutil detach "$mount_point" -quiet 2>/dev/null || true; mount_point=; }
fi

# ---------- 打补丁 ----------
# 替换后重新判定：已是补丁态说明本次无需重复写入（补丁器会要求解验证码）
pre_patch_state=$(patch_state)
if [[ "$pre_patch_state" == 已打补丁 ]]; then
    printf '\n补丁已就绪，无需重复应用。\n'
    printf '版本：%s\n' "$(version_at "$app")"
    printf '补丁状态：%s\n' "$pre_patch_state"
    /usr/bin/open -a "$app" 2>/dev/null || true
    printf '完成。\n'
    exit 0
fi

printf '正在应用授权补丁…\n'
patch_target=$("$python" - "$patcher" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from patcher.manager.discovery import find_manager_binary
print(find_manager_binary() or '')
PY
)
[[ -n "$patch_target" ]] || fail '未找到 language_server，无法打补丁。'

# 客户端若由其他账号或提权安装，属主会与当前用户不一致，导致无法写入
if [[ ! -w "$patch_target" ]]; then
    printf '客户端文件归属与当前用户不一致，需要一次管理员授权来修正（会弹出系统对话框）…\n'
    /usr/bin/osascript <<OSA || fail '未获得管理员授权，已停止。客户端不受影响，仍可正常启动。'
do shell script "/usr/sbin/chown -R $(/usr/bin/id -u) $(printf '%q' "$app")" with administrator privileges
OSA
    [[ -w "$patch_target" ]] || fail '文件仍不可写，请检查系统隐私与权限设置。'
    printf '归属已修正，后续无需再次授权。\n'
fi

if ! "$python" -c '
import sys
sys.path.insert(0, sys.argv[1])
from patcher.manager.discovery import find_manager_binary
from patcher.manager.patcher import do_patch_manager
target = find_manager_binary()
if not target:
    print("未找到 language_server")
    raise SystemExit(2)
print("目标：" + target)
do_patch_manager(target)
' "$patcher" </dev/null; then
    printf '\n补丁未成功。客户端已是官方最新版，可正常启动。\n' >&2
    exit 1
fi

final_state=$(patch_state)
if [[ "$final_state" != 已打补丁 ]]; then
    printf '\n补丁未生效（当前状态：%s）。客户端可正常启动，但授权补丁需重新应用。\n' "$final_state" >&2
    exit 1
fi

# ---------- 结果 ----------
printf '\n补丁状态：%s\n' "$final_state"
printf '版本：%s\n' "$(version_at "$app")"
/usr/bin/open -a "$app" 2>/dev/null || true
printf '完成。\n'
