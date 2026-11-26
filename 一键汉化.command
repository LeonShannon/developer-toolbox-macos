#!/bin/bash
set -euo pipefail
umask 077

app=/Applications/Antigravity.app
plist="$app/Contents/Info.plist"
target="$app/Contents/Resources/app.asar"
repo=antigravity-cn-community/Antigravity-Chinese-Localization
store="$HOME/Library/Application Support/开发工具箱/Antigravity"
process='^/Applications/Antigravity[.]app/Contents/MacOS/Antigravity( |$)'

fail() { printf '停止：%s\n' "$*" >&2; exit 1; }
version_at_app() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist"; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
json() { /usr/bin/plutil -extract "$1" raw -o - "$metadata" 2>/dev/null; }
fetch() {
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' \
        --proto-redir '=https' --connect-timeout 10 --max-time 120 "$1" -o "$2"
}

[[ "$(/usr/bin/uname -s)" == Darwin && -f "$target" ]] || fail '此入口需要 macOS 上的 /Applications/Antigravity.app。'
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" == com.google.antigravity ]] ||
    fail '无法确认客户端身份。'
version=$(version_at_app) || fail '无法读取客户端版本。'
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "无法识别客户端版本 $version。"
printf '本机 Antigravity %s\n' "$version"
/bin/mkdir -p "$store"
/bin/mkdir "$store/.lock" 2>/dev/null || fail "已有任务正在运行。若上次异常退出，请先确认没有任务，再移除 $store/.lock。"
scratch=
trap '[[ -z "$scratch" ]] || /bin/rm -rf "$scratch"; /bin/rmdir "$store/.lock"' EXIT
scratch=$(/usr/bin/mktemp -d "$store/.正在检查.XXXXXX")
metadata="$scratch/release.json"
fetch "https://api.github.com/repos/$repo/releases/tags/v$version" "$metadata" ||
    fail "无法取得 v$version 的发布信息。请检查网络和上游是否已适配。"
[[ "$(json tag_name)" == "v$version" && "$(json draft)" == false && "$(json prerelease)" == false ]] ||
    fail "上游发布版本与本机 $version 不完全匹配。"

index=0
while name=$(json "assets.$index.name"); do
    [[ "$name" == app.asar ]] && break
    index=$((index + 1))
done
[[ "${name:-}" == app.asar ]] || fail '匹配的发布没有 app.asar 文件。'
digest=$(json "assets.$index.digest") || fail '发布未提供补丁 SHA-256。'
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail '补丁 SHA-256 格式有误。'
digest=${digest#sha256:}
url=$(json "assets.$index.browser_download_url") || fail '发布未提供补丁下载地址。'
[[ "$url" == "https://github.com/$repo/releases/download/v$version/app.asar" ]] || fail '补丁下载地址与发布不符。'

cache="$store/$version"
patch="$cache/$digest.asar"
backup="$cache/app.asar.bak"
receipt="$cache/已安装.sha256"
printf '匹配的上游补丁：v%s\nSHA-256：%s\n' "$version" "$digest"
if [[ -f "$patch" && "$(sha "$patch")" == "$digest" ]]; then
    printf '已缓存这个补丁。\n'
fi
current=$(sha "$target")
if [[ "$current" == "$digest" ]]; then
    printf '当前客户端已安装这个补丁。\n'
fi
case "${1:-}" in
    --download) ;;
    --install)
        [[ "$current" != "$digest" ]] || exit 0
        printf '等待确认安装汉化补丁\n'
        if ! read -r confirmation || [[ "$confirmation" != 确认安装 ]]; then
            printf '已取消安装。\n'
            exit 0
        fi
        ;;
    *) fail '请从开发工具箱选择下载补丁或应用到 Antigravity。' ;;
esac

/bin/mkdir -p "$cache"
if [[ ! -f "$patch" || "$(sha "$patch")" != "$digest" ]]; then
    fetch "$url" "$scratch/app.asar" || fail '补丁下载失败。'
    [[ "$(sha "$scratch/app.asar")" == "$digest" ]] || fail '补丁 SHA-256 校验失败。'
    /bin/mv -f "$scratch/app.asar" "$patch"
fi
printf '补丁已下载并校验：%s\n' "$patch"
[[ "$1" == --install ]] || exit 0

# 只有 Google 签名校验通过的客户端才可作为首次备份的来源。
if /usr/bin/codesign --verify --strict -R='anchor apple generic and identifier "com.google.antigravity" and certificate leaf[subject.OU] = "EQHXZ8M8AV"' "$app" 2>/dev/null; then
    /bin/cp -p "$target" "$scratch/app.asar.bak"
    [[ "$(sha "$scratch/app.asar.bak")" == "$current" ]] || fail '原版备份校验失败。'
    /bin/mv -f "$scratch/app.asar.bak" "$backup"
    printf '%s\n' "$current" > "$cache/原版.sha256"
else
    [[ -f "$receipt" && "$(< "$receipt")" == "$current" && -f "$backup" &&
       -f "$cache/原版.sha256" && "$(sha "$backup")" == "$(< "$cache/原版.sha256")" ]] ||
        fail '当前客户端的原版无法验证。请用 Google 官方完整安装包覆盖安装，再从工具箱应用汉化。'
fi
[[ -w "${target%/*}" ]] || fail '当前用户没有写入 Antigravity 资源目录的权限。'

replace_asar() {
    local source=$1 temporary
    temporary=$(/usr/bin/mktemp "${target%/*}/.toolbox-asar.XXXXXX") || return 1
    if /bin/cp -p "$source" "$temporary" && /bin/mv -f "$temporary" "$target"; then
        return 0
    fi
    /bin/rm -f "$temporary"
    return 1
}

install_patch() {
    /bin/sleep 2
    [[ "$(version_at_app)" == "$version" && "$(sha "$target")" == "$current" &&
       "$(sha "$patch")" == "$digest" ]] || fail '客户端或补丁发生变化，请重新检查。'
    /bin/cp -p "$target" "$scratch/before.asar"
    [[ "$(sha "$scratch/before.asar")" == "$current" ]] || fail '安装前副本校验失败。'
    if /usr/bin/pgrep -f "$process" >/dev/null; then
        /usr/bin/pkill -TERM -f "$process" || true
        for ((attempt=0; attempt<15; attempt++)); do
            /usr/bin/pgrep -f "$process" >/dev/null || break
            /bin/sleep 1
        done
        ! /usr/bin/pgrep -f "$process" >/dev/null || fail '客户端仍在运行，已停止安装。'
    fi
    [[ "$(version_at_app)" == "$version" && "$(sha "$target")" == "$current" ]] ||
        fail '关闭客户端时版本或文件发生变化，请重新检查。'
    if ! replace_asar "$patch"; then
        /usr/bin/open -a "$app" || true
        fail '无法替换补丁。若 macOS 提示允许终端修改其他 App，请按提示处理后重试。'
    fi
    if [[ "$(sha "$target")" == "$digest" ]] && /usr/bin/open -a "$app"; then
        /bin/sleep 5
        if /usr/bin/pgrep -f "$process" >/dev/null; then
            printf '%s\n' "$digest" > "$scratch/已安装.sha256"
            /bin/mv -f "$scratch/已安装.sha256" "$receipt"
            printf '汉化补丁已安装，客户端进程已启动。\n'
            return
        fi
    fi
    /usr/bin/pkill -TERM -f "$process" 2>/dev/null || true
    replace_asar "$scratch/before.asar" || fail "自动回滚失败。可用 $backup 恢复纯净原版。"
    /usr/bin/open -a "$app" || true
    fail '客户端启动检查失败，已还原安装前的 app.asar。'
}

install_patch </dev/null &
wait "$!"
