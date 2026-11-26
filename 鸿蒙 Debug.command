#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --list-devices ]; then
  /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets |
    /usr/bin/awk 'NF == 1 && $1 != "[Empty]" {print $1 "\t" $1}'
  exit
fi
trap 'status=$?; echo; if [ "$status" -ne 0 ]; then echo "执行失败（${status}），请查看上面的信息。"; fi; read -r -p "按回车关闭窗口..." _ || true' EXIT

build_mode=debug
if [[ "${1:-}" == --release ]]; then
  build_mode=release
  shift
  case "${1:-}" in 1|2) ;; *) echo '请选择 Release 打包操作。'; exit 2 ;; esac
fi

source "$(dirname -- "${BASH_SOURCE[0]}")/toolbox-config.sh"
project=$(toolbox_project HarmonyProject)
studio=/Applications/DevEco-Studio.app/Contents
hdc="$studio/sdk/default/openharmony/toolchains/hdc"
export DEVECO_SDK_HOME="$studio/sdk"
export HVIGOR_USER_HOME="$project/.hvigor_user_home"
export PATH="$studio/tools/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$project"
echo "鸿蒙 ${build_mode}：当前分支 $(git branch --show-current)"
if [ "$#" -gt 0 ]; then
  choice=$1
else
  echo '1. 仅打包   2. 打包、安装并启动   其他键退出'
  read -r -p '请选择：' choice
fi
case "$choice" in 1|2) ;; *) exit 0 ;; esac

if [ "$choice" = 2 ]; then
  package=$(toolbox_require HarmonyPackage)
  ability=$(toolbox_require HarmonyAbility)
  devices=$("$hdc" list targets | sed '/^\[Empty\]$/d; /^$/d')
  count=$(printf '%s\n' "$devices" | awk 'NF {n++} END {print n+0}')
  if [ "$#" -gt 0 ]; then
    if [ -z "${2:-}" ] || ! printf '%s\n' "$devices" | /usr/bin/grep -Fxq -- "$2"; then
      echo '所选鸿蒙设备已断开或未授权。'
      exit 1
    fi
    devices=$2
  elif [ "$count" -ne 1 ]; then
    echo "请只连接并授权一台鸿蒙设备，当前可用设备数：$count"
    "$hdc" list targets
    exit 1
  fi
  device="$devices"
  echo "目标设备：$device"
fi

profile=Debug
if [[ "$build_mode" == release ]]; then profile=Release; fi
product=$(toolbox_require "Harmony${profile}Product")
module=$(toolbox_require HarmonyModule)
hap=$(toolbox_require "Harmony${profile}Hap")
"$studio/tools/hvigor/bin/hvigorw" assembleHap --mode module -p "product=$product" -p "buildMode=$build_mode" -p "module=$module" --no-daemon
hap="$project/$hap"
[ -f "$hap" ] || { echo "找不到已签名 HAP：$hap"; exit 1; }
echo "打包完成：$hap"
if [ "$choice" = 1 ]; then open -R "$hap"; fi
if [ "$choice" = 2 ]; then
  result=$("$hdc" -t "$device" install -r "$hap" 2>&1) || { echo "$result"; exit 1; }
  echo "$result"
  [[ "$result" == *"install bundle successfully"* ]] || { echo '安装未确认成功，请检查上方输出。'; exit 1; }
  result=$("$hdc" -t "$device" shell aa start -a "$ability" -b "$package" 2>&1) || { echo "$result"; exit 1; }
  echo "$result"
  [[ "$result" == *"start ability successfully"* ]] || { echo '启动未确认成功，请检查上方输出。'; exit 1; }
  echo '已发送启动请求，请在设备上确认应用运行。'
fi
