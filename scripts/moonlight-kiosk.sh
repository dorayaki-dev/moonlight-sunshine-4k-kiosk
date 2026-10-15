#!/usr/bin/env bash
# moonlight-kiosk.sh — runs inside the X session started by moonlight.service
# 由 xinit 在独立 X 会话里拉起，输出到电视（HDMI）。
#
# 关键点 / The important bits
#  1. 配置目录必须固定，且 export 要放在**直连分支之前**（否则 CLI 会用未配对的身份）
#  2. HDMI 音频设备要在运行时探测（card 序号会漂移），并顺手打开 IEC958 开关
#  3. 客户端日志默认进 tty，journal 里看不到 → 重定向到文件
#  4. 直连模式套 while 循环实现断线自恢复
set -uo pipefail

KIOSK_DIR="${KIOSK_DIR:-/opt/moonlight-kiosk}"
MOON="${MOON:-$KIOSK_DIR/moonlight/squashfs-root/AppRun}"   # Moonlight AppImage 解包路径
CFG_DIR="${CFG_DIR:-$KIOSK_DIR/config}"                     # 固定且已配对的配置目录
LOG=/tmp/moonlight.log

# ── 配置目录（必须在直连分支之前！）─────────────────────────────────────────
export XDG_CONFIG_HOME="$CFG_DIR"
export XDG_CACHE_HOME="$KIOSK_DIR/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# ── 音频：探测 HDMI 设备 + 打开 IEC958 ────────────────────────────────────
if [ -x "$KIOSK_DIR/hdmi-audio.sh" ]; then
  AUDIODEV=$(bash "$KIOSK_DIR/hdmi-audio.sh" 2>>"$LOG") || true
  [ -n "${AUDIODEV:-}" ] && export AUDIODEV
fi
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-alsa}"

# ── 日志：客户端输出默认进 tty，这里转存文件 ───────────────────────────────
export QT_LOGGING_RULES="qt.network.ssl=true"
exec 2>>"$LOG"

# ── 可选：设置电视输出模式（按你的 EDID 修改，或交给 xrandr 自动）──────────
SCREEN="${OUT_MODE:-3840x2160}"
RATE="${OUT_RATE:-60}"
if command -v xrandr >/dev/null && [ -n "${OUTPUT:-}" ]; then
  xrandr --output "$OUTPUT" --mode "$SCREEN" --rate "$RATE" 2>/dev/null || true
fi

# ── 最小窗口管理器（没有 WM 时 Qt 窗口拿不到正确尺寸）──────────────────────
if command -v openbox >/dev/null; then
  openbox --sm-disable >/dev/null 2>&1 &
  sleep 2
fi

# ── 直连串流模式（推荐）：在 $KIOSK_DIR/moonlight.conf 里设 MOON_HOST/MOON_APP ──
# 例：MOON_HOST=192.168.1.50  MOON_APP=Desktop  MOON_RES=4K  MOON_FPS=60  MOON_BITRATE=60000
[ -f "$KIOSK_DIR/moonlight.conf" ] && . "$KIOSK_DIR/moonlight.conf"

if [ -n "${MOON_HOST:-}" ] && [ -n "${MOON_APP:-}" ]; then
  while true; do
    "$MOON" stream "$MOON_HOST" "$MOON_APP" \
      --display-mode fullscreen "--${MOON_RES:-4K}" \
      --fps "${MOON_FPS:-60}" --bitrate "${MOON_BITRATE:-60000}" \
      --audio-config stereo >>"$LOG" 2>&1
    echo "[kiosk] $(date +%H:%M:%S) stream ended, reconnecting in 5s ..." >>"$LOG"
    sleep 5
  done
fi

# ── 默认：全屏 GUI（主机列表），用遥控/键鼠选 ─────────────────────────────
"$MOON" &
MOON_PID=$!

# 把 Qt 窗口撑到全屏（拿不到 WM 提示时的手动兜底）
fit_window() {
  local wid geo
  for _ in $(seq 1 30); do
    for wid in $(xdotool search --name "Moonlight" 2>/dev/null); do
      geo=$(xdotool getwindowgeometry "$wid" 2>/dev/null | awk '/Geometry/{print $2}')
      [ "$geo" = "$SCREEN" ] && return 0
      xdotool windowmove "$wid" 0 0 2>/dev/null
      xdotool windowsize "$wid" "${SCREEN%x*}" "${SCREEN#*x}" 2>/dev/null
    done
    sleep 1
  done
}
fit_window
wait "$MOON_PID"
