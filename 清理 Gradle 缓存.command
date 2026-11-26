#!/bin/bash
set -euo pipefail

gradle_dir=${GRADLE_USER_HOME:-"$HOME/.gradle"}
cache="$gradle_dir/caches/build-cache-1"
if [[ ! -d "$cache" || -L "$cache" ]]; then
    printf '找不到可清理的构建缓存：%s\n' "$cache"
    exit 0
fi

identity=$(/usr/bin/stat -f '%d:%i:%m:%c' "$cache")
/usr/bin/du -sh "$cache"
[[ "${1:-}" != --preview ]] || exit 0

printf '请先结束正在运行的 Gradle 构建和 IDE 同步。移动后，下次构建可能变慢。\n'
printf '输入 CLEAN 移到废纸篓，直接回车取消：\n'
if ! IFS= read -r answer || [[ "$answer" != CLEAN ]]; then
    printf '已取消。\n'
    exit 0
fi

if [[ -L "$cache" || "$(/usr/bin/stat -f '%d:%i:%m:%c' "$cache")" != "$identity" ]]; then
    printf '缓存目录有变化，请重新预览。\n' >&2
    exit 1
fi

trash="$HOME/.Trash"
[[ -d "$trash" && ! -L "$trash" ]] || { printf '无法使用废纸篓：%s\n' "$trash" >&2; exit 1; }
if [[ "$(/usr/bin/stat -f '%d' "$trash")" != "${identity%%:*}" ]]; then
    printf '缓存和废纸篓位于不同磁盘。\n' >&2
    exit 1
fi
batch=$(/usr/bin/mktemp -d "$trash/Gradle-build-cache.XXXXXXXX")
if ! /bin/mv -- "$cache" "$batch/"; then
    /bin/rmdir "$batch"
    exit 1
fi
printf '已移到废纸篓：%s\n清空对应的废纸篓批次后才会释放空间。\n' "$batch"
