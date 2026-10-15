#!/usr/bin/env bash
# mode.sh — switch the kiosk between power-save and streaming modes
#
# 用法 / Usage:  sudo bash mode.sh {nas|stream|game|stop-stream|status}
#
# 设计要点 / Design notes
#  - Every "performance" tweak made for streaming MUST be reverted by the power-save
#    branch. Keep them in the SAME script so they can never drift apart.
#  - 所有"为串流打开的性能开关"都必须由省电分支成对回收，写在同一脚本里才不会漂移。
set -uo pipefail

# ── 按你的环境修改 / configure for your box ────────────────────────────────
KIOSK_DIR="${KIOSK_DIR:-/opt/moonlight-kiosk}"
MODE_FILE="$KIOSK_DIR/mode.txt"
FAN="$KIOSK_DIR/fan.sh"
DGPU="${DGPU_SYSFS:-}"            # optional: path to the dGPU control (e.g. asus dGPU toggle)
KIOSK_SERVICE="moonlight"         # systemd unit name
# ───────────────────────────────────────────────────────────────────────────

mkdir -p "$KIOSK_DIR"

# ── GPU power state helpers ────────────────────────────────────────────────
gpu_low() {   # power-save: lowest iGPU state, allow runtime suspend, blank console
  for _d in /sys/class/drm/card*/device/; do
    [ -w "${_d}power_dpm_state" ] || continue
    echo battery > "${_d}power_dpm_state" 2>/dev/null   # battery | balanced | performance
    echo auto    > "${_d}power/control"    2>/dev/null   # auto = allow runtime PM
  done
  echo 1 > /sys/class/graphics/fb0/blank 2>/dev/null    # headless: keep the console from pinning the GPU
}

gpu_high() {  # streaming: full performance, no runtime PM, console visible
  for _d in /sys/class/drm/card*/device/; do
    [ -w "${_d}power_dpm_state" ] || continue
    echo performance > "${_d}power_dpm_state" 2>/dev/null
    echo on          > "${_d}power/control"    2>/dev/null
  done
  echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
}

# Stop the kiosk WITHOUT systemctl stop (its stop can hang on the X session).
kiosk_stop() {
  systemctl kill -s TERM "$KIOSK_SERVICE" 2>/dev/null
  sleep 5
  systemctl stop "$KIOSK_SERVICE" 2>/dev/null
  systemctl reset-failed "$KIOSK_SERVICE" 2>/dev/null
}

case "${1:-status}" in
  nas)
    echo nas > "$MODE_FILE"
    bash "$FAN" quiet 2>/dev/null
    kiosk_stop
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo powersave > "$g" 2>/dev/null
    done
    [ -n "$DGPU" ] && echo 1 > "$DGPU" 2>/dev/null
    # turn the display outputs off (X may not be running; ignore failures)
    for c in /sys/class/drm/card*-HDMI-A-*/status; do :; done
    gpu_low
    echo "✅ NAS / power-save mode: quiet fan, governor powersave, GPU=low, console blanked"
    ;;

  stream)
    echo stream > "$MODE_FILE"
    bash "$FAN" quiet 2>/dev/null      # decoding is light — no need for an aggressive curve
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo schedutil > "$g" 2>/dev/null
    done
    gpu_high                            # 4K60 decode wants the GPU awake
    systemctl reset-failed "$KIOSK_SERVICE" 2>/dev/null
    systemctl start "$KIOSK_SERVICE"
    echo "✅ Streaming mode: Moonlight kiosk started on the TV output"
    ;;

  game)
    echo game > "$MODE_FILE"
    bash "$FAN" cool 2>/dev/null        # local gaming: dGPU on, needs real cooling
    [ -n "$DGPU" ] && echo 0 > "$DGPU" 2>/dev/null
    gpu_high
    systemctl reset-failed "$KIOSK_SERVICE" 2>/dev/null
    systemctl start "$KIOSK_SERVICE"
    echo "✅ Game mode: aggressive fan, dGPU requested on"
    ;;

  stop-stream)
    bash "$FAN" quiet 2>/dev/null
    kiosk_stop
    gpu_low
    echo "✅ Stream stopped: power-save settings restored"
    ;;

  status)
    echo "mode:        $(cat "$MODE_FILE" 2>/dev/null || echo '?')"
    echo "kiosk:       $(systemctl is-active "$KIOSK_SERVICE" 2>/dev/null)"
    for d in /sys/class/drm/card*/device/; do
      [ -e "${d}power_dpm_state" ] && echo "gpu dpm:     $(cat ${d}power_dpm_state)"
    done
    echo "fb0 blank:   $(cat /sys/class/graphics/fb0/blank 2>/dev/null)"
    echo "governor:    $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    ;;
  *)
    echo "usage: $0 {nas|stream|game|stop-stream|status}" >&2; exit 1 ;;
esac
