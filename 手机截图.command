#!/bin/zsh

fail() {
    print -u2 -r -- "$1"
    exit 1
}

temp_root=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)}
[[ -n "$temp_root" && -d "$temp_root" ]] || fail "无法找到 macOS 临时目录。"
outdir="${temp_root%/}/手机截图"

if [[ "${1:-}" == --save-last ]]; then
    typeset -a captures
    captures=("$outdir"/(Android-*.png|鸿蒙-*.jpeg)(Nom.))
    (( ${#captures} )) || fail "没有可保存的截图，请先截取屏幕。"
    source=${captures[1]}
    desktop="$HOME/Desktop/${source:t}"
    if ! /usr/bin/cmp -s -- "$source" "$desktop"; then
        [[ ! -e "$desktop" && ! -L "$desktop" ]] || fail "桌面已有同名文件，无法保存截图。"
        /bin/cp -n -- "$source" "$desktop" || fail "无法复制截图到桌面。"
    fi
    print -r -- "已保存到 $desktop"
    exit 0
fi

export PATH="$HOME/Library/Android/sdk/platform-tools:/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:/opt/homebrew/bin:/usr/local/bin:$PATH"

typeset -a platforms serials labels
if command -v adb >/dev/null && android=$(adb devices -l); then
    while read -r serial device_state details; do
        [[ "$device_state" == device ]] || continue
        model=${details#*model:}
        [[ "$model" != "$details" ]] && model=${model%% *} || model="$serial"
        platforms+=(Android)
        serials+=("$serial")
        labels+=("$model")
    done <<< "$android"
fi

if command -v hdc >/dev/null && harmony=$(hdc list targets -v); then
    while read -r serial transport device_state details; do
        [[ "$device_state" == Connected ]] || continue
        model=$(hdc -t "$serial" shell "param get const.product.name" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$model" || "$model" == *"fail!"* ]]; then
            model=$(hdc -t "$serial" shell "param get const.product.model" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
        [[ -z "$model" || "$model" == *"fail!"* ]] && model="$serial"
        platforms+=(鸿蒙)
        serials+=("$serial")
        labels+=("$model")
    done <<< "$harmony"
fi

if [[ "${1:-}" == --list-devices ]]; then
    for (( i = 1; i <= ${#serials}; i++ )); do
        printf '%s\t%s\t%s\n' "${platforms[i]}" "${serials[i]}" "${labels[i]}"
    done
    exit 0
fi

if [[ "$#" -gt 0 ]]; then
    choice=
    for (( i = 1; i <= ${#serials}; i++ )); do
        if [[ "${platforms[i]}" == "$1" && "${serials[i]}" == "${2:-}" ]]; then
            choice=$i
            break
        fi
    done
    [[ -n "$choice" ]] || fail "所选设备已断开或未授权。"
else
case ${#serials} in
    0) fail "没找到已授权的手机。请插上数据线，打开并授权 USB 调试，再运行一次。" ;;
    1) choice=1 ;;
    *)
        for (( i = 1; i <= ${#labels}; i++ )); do
            print -r -- "$i. ${labels[i]}"
        done
        read -r 'choice?输入设备编号，按回车（直接回车取消）：' || exit 0
        [[ -n "$choice" ]] || exit 0
        [[ "$choice" =~ '^[1-9][0-9]*$' && ${#choice} -le ${#${#serials}} ]] && (( choice <= ${#serials} )) || fail "设备编号无效。"
        ;;
esac
fi

serial=${serials[choice]}
platform=${platforms[choice]}
mkdir -p -- "$outdir" || fail "无法创建截图目录。"
work=$(mktemp -d "$outdir/.capture.XXXXXXXX") || fail "无法创建截图临时目录。"
remote=
cleanup() {
    if [[ -n "$remote" ]]; then
        hdc -t "$serial" shell rm -f "$remote" >/dev/null 2>&1
    fi
    rm -f -- "$work/截图.png" "$work/截图.jpeg"
    rmdir -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print -r -- "正在截取 ${labels[choice]} 的当前屏幕…"
if [[ "$platform" == Android ]]; then
    format=png
    adb -s "$serial" exec-out screencap -p > "$work/截图.png" || fail "Android 截图失败。"
else
    format=jpeg
    remote="/data/local/tmp/codex-mobile-${work##*.}.jpeg"
    hdc -t "$serial" shell snapshot_display -f "$remote" || fail "鸿蒙截图失败。"
    hdc -t "$serial" file recv "$remote" "$work/截图.jpeg" || fail "无法把截图传回 Mac。"
fi

info=$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$work/截图.$format" 2>/dev/null)
[[ "$info" == *"format: $format"* && "$info" == *"pixelWidth: "[1-9]* && "$info" == *"pixelHeight: "[1-9]* ]] ||
    fail "手机没有返回可读取的截图。"

output="$outdir/$platform-$(date '+%Y%m%d-%H%M%S')-${work##*.}.$format"
mv -- "$work/截图.$format" "$output" || fail "无法保存截图。"
print -r -- "已临时保存到 $output"
if /usr/bin/osascript - "$output" <<'APPLESCRIPT'
use framework "AppKit"
use scripting additions

on run argv
    set imageFile to current application's NSImage's alloc()'s initWithContentsOfFile:(item 1 of argv)
    if imageFile is missing value then error "无法读取截图图像"
    set imageData to imageFile's TIFFRepresentation()
    if imageData is missing value then error "无法转换截图图像"
    set pasteboardRef to current application's NSPasteboard's generalPasteboard()
    pasteboardRef's declareTypes:{current application's NSPasteboardTypeTIFF} owner:(missing value)
    if not (pasteboardRef's setData:imageData forType:(current application's NSPasteboardTypeTIFF)) then error "无法写入剪贴板"
end run
APPLESCRIPT
then
    print -r -- "截图已复制到剪贴板，可按 ⌘V 粘贴。"
else
    print -u2 -r -- "复制到剪贴板失败，可以使用「保存上次截图到桌面」。"
fi
