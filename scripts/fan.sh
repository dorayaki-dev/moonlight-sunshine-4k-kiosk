#!/usr/bin/env bash
# fan.sh — fan-curve presets for the kiosk box.
#
# 用法 / Usage:  sudo bash fan.sh {quiet|cool|auto|status}
#
# 本脚本针对 **ASUS** 机型（hwmon 里的 `asus_custom_fan_curve`）。
# 非 ASUS 机型请把 apply() 换成你的平台接口（thinkfan / nbfc / platform_profile 等），
# 曲线的设计思路照抄即可：安静档在 ~50°C 以下停转，88°C 起接近满速。
set -uo pipefail

C=""
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name" 2>/dev/null)" = "asus_custom_fan_curve" ] && C=$h
done
if [ -z "$C" ]; then
  echo "fan.sh: asus_custom_fan_curve not found — this box type is unsupported (see comments)" >&2
  exit 1
fi

BK="$HOME/fan_curve_backup.txt"
[ -f "$BK" ] || { for f in 1 2; do for i in 1 2 3 4 5 6 7 8; do
    echo "pwm${f}_auto_point${i}_temp=$(cat $C/pwm${f}_auto_point${i}_temp 2>/dev/null)" >> "$BK"
    echo "pwm${f}_auto_point${i}_pwm=$(cat $C/pwm${f}_auto_point${i}_pwm 2>/dev/null)"  >> "$BK"
  done; done; echo "backed up original curve → $BK"; }

# $1 = 8 temperature points   $2 = 8 duty values (0-255)
apply() {
  local i=1 t p
  for t in $1; do
    p=$(echo "$2" | cut -d' ' -f$i)
    for f in 1 2; do
      echo "$t" > "$C/pwm${f}_auto_point${i}_temp" 2>/dev/null
      echo "$p" > "$C/pwm${f}_auto_point${i}_pwm"  2>/dev/null
    done
    i=$((i+1))
  done
  for f in 1 2; do echo 1 > "$C/pwm${f}_enable"; done   # 1 = custom curve, 2 = hand back to EC
}

case "${1:-status}" in
  quiet)  # 停转 → 11% → … → 满速。适合 24/7 待机与串流（解码负载很轻）
    apply "50 58 64 70 76 82 88 95" "0 30 70 110 150 190 230 255"
    echo "fan: QUIET curve (0% below 50°C, 11% @58°C, 100% @95°C)";;
  cool)   # 40°C 就起转。只在你真的在本地跑游戏/编译时用
    apply "40 45 50 55 60 65 72 80" "60 100 150 190 220 240 255 255"
    echo "fan: AGGRESSIVE curve (starts at 40°C)";;
  auto)   # 交还给 EC / 厂商固件
    for f in 1 2; do echo 2 > "$C/pwm${f}_enable"; done
    echo "fan: handed back to EC auto";;
  status)
    for i in 1 2 3 4 5 6 7 8; do
      printf "  point%s: %s°C → %s/255\n" "$i" \
        "$(cat $C/pwm1_auto_point${i}_temp 2>/dev/null)" "$(cat $C/pwm1_auto_point${i}_pwm 2>/dev/null)"
    done
    echo "  enable: $(cat $C/pwm1_enable 2>/dev/null) (1=custom, 2=EC auto)";;
  *) echo "usage: $0 {quiet|cool|auto|status}" >&2; exit 1;;
esac
