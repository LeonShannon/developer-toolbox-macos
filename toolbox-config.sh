# 由同目录的打包脚本加载。
toolbox_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
toolbox_config="$toolbox_directory/toolbox.local.plist"
toolbox_get() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$toolbox_config" 2>/dev/null
}
toolbox_require() {
  local value
  if ! value=$(toolbox_get "$1") || [[ -z "$value" ]]; then
    echo "请在 toolbox.local.plist 中填写 $1。" >&2
    return 2
  fi
  printf '%s\n' "$value"
}
toolbox_project() {
  local path
  path=$(toolbox_require "$1") || return
  path="${path/#\~\//$HOME/}"
  if [[ "$path" != /* || ! -d "$path" ]]; then
    echo "项目目录无效：$path。请使用绝对路径或 ~/ 开头的路径。" >&2
    return 2
  fi
  printf '%s\n' "$path"
}
