#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --list-devices ]; then
  "$HOME/Library/Android/sdk/platform-tools/adb" devices -l | /usr/bin/awk '$2=="device" {print $1 "\t" $0}'
  exit
fi
trap 'status=$?; echo; if [ "$status" -ne 0 ]; then echo "执行失败（${status}），请查看上面的信息。"; fi; read -r -n 1 -s -p "按任意键关闭窗口..." _ || true; echo' EXIT

build_mode=debug
if [[ "${1:-}" == --release ]]; then
  build_mode=release
  shift
  case "${1:-}" in 1|2) ;; *) echo '请选择 Release 打包操作。'; exit 2 ;; esac
fi

source "$(dirname -- "${BASH_SOURCE[0]}")/toolbox-config.sh"
project=$(toolbox_project AndroidProject)
adb="$HOME/Library/Android/sdk/platform-tools/adb"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
export PATH="$JAVA_HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$project"
if [[ "${1:-}" == --rebuild-channel ]]; then
  channel_task=$(toolbox_require AndroidChannelTask)
  echo "Android 渠道重打包：当前分支 $(git branch --show-current)"
  exec ./gradlew "$channel_task" --no-configuration-cache
fi
echo "Android ${build_mode}：当前分支 $(git branch --show-current)"
if [ "$#" -gt 0 ]; then
  choice=$1
else
  echo '1. 仅打包   2. 打包、安装并启动   其他键退出'
  read -r -p '请选择：' choice
fi
case "$choice" in 1|2) ;; *) exit 0 ;; esac

if [ "$choice" = 2 ]; then
  package=$(toolbox_require AndroidPackage)
  device_list=$("$adb" devices | awk 'NR>1 && $2=="device" {print $1}')
  devices=()
  while IFS= read -r serial; do
    [ -z "$serial" ] || devices+=("$serial")
  done <<< "$device_list"
  if [ "${#devices[@]}" -eq 0 ]; then
    echo '没有找到已授权的 Android 设备。'
    "$adb" devices
    exit 1
  fi
  if [ "$#" -gt 0 ]; then
    device=${2:-}
    if [ -z "$device" ] || ! printf '%s\n' "${devices[@]}" | /usr/bin/grep -Fxq -- "$device"; then
      echo '所选 Android 设备已断开或未授权。'
      exit 1
    fi
  elif [ "${#devices[@]}" -eq 1 ]; then
    device="${devices[0]}"
  else
    echo '请选择要安装的设备：'
    labels=()
    for serial in "${devices[@]}"; do
      model=$("$adb" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)
      labels+=("${model:-型号未知} ($serial)")
    done
    PS3='输入设备编号：'
    select label in "${labels[@]}" '取消'; do
      if [ "$label" = '取消' ]; then exit 0; fi
      if [ -n "$label" ]; then
        for ((i=0; i<${#labels[@]}; i++)); do
          if [ "$label" = "${labels[i]}" ]; then device="${devices[i]}"; break; fi
        done
        break
      fi
      echo '请输入列表中的编号。'
    done
    [ -n "${device:-}" ] || exit 1
  fi
  echo "目标设备：$device"
fi

profile=Debug
if [[ "$build_mode" == release ]]; then profile=Release; fi
task=$(toolbox_require "Android${profile}Task")
metadata=$(toolbox_require "Android${profile}Metadata")
./gradlew "$task"
metadata="$project/$metadata"
apk=$(python3 -c 'import json,os,sys; p=sys.argv[1]; d=json.load(open(p)); e=d["elements"]; assert len(e)==1, "APK 数量不是一个，请检查构建产物"; print(os.path.join(os.path.dirname(p),e[0]["outputFile"]))' "$metadata")
[ -f "$apk" ] || { echo "找不到 APK：$apk"; exit 1; }
echo "打包完成：$apk"
if [ "$choice" = 1 ]; then open -R "$apk"; fi
if [ "$choice" = 2 ]; then
  "$adb" -s "$device" install -r "$apk"
  "$adb" -s "$device" shell monkey -p "$package" -c android.intent.category.LAUNCHER 1
  echo '已发送启动请求，请在设备上确认应用运行。'
fi
