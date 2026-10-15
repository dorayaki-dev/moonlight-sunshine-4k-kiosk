# 02 · 4K60 不生效、以及 resume 会沿用旧规格

## 症状

- 4K 电视上画面明显发糊，像被放大过
- 客户端日志写着 `Video stream is 1920x1080x60`
- 电视性能浮层显示 `Video stream: 1920x1080`

## 原因 A：Moonlight GUI 默认就请求 1080p，且配置改不动

Moonlight 的默认串流规格是 **1080p60**。你以为改 `Moonlight.conf` 就行？实测：

```ini
# 这些键写进去会被程序忽略/覆盖 ✗
width=3840
height=2160
fps=60
bitrate=100000
```

重启客户端后，这些键会被程序自己的状态覆盖回去，launch 请求仍然是 `mode=1920x1080x60` ✗

**正解：用命令行直连模式**（脚本里让 `MOON_HOST` / `MOON_APP` 有值即走这条分支）：

```bash
"$MOONLIGHT" stream "$MOON_HOST" "$MOON_APP" \
  --display-mode fullscreen --4K --fps 60 --bitrate 60000 --audio-config stereo
```

- `MOON_APP=Desktop` 表示串整个桌面（Sunshine 应用列表里的第一个应用通常就是它）
- 分辨率取值：`--720 / --1080 / --1440 / --4K`；`--audio-config stereo`
- 4K60 建议码率 **40~80 Mbps**（HEVC），前提是**有线千兆**；Wi-Fi 上请降到 1080p

验证（客户端日志）：

```
Executing request: "https://<HOST>:47984/launch?uniqueid=...&appid=...&mode=3840x2160x60..."
SDL Info: Video stream is 3840x2160x60 (format 0x100)
```

电视上按 **Ctrl+Alt+Shift+S** 调出浮层，应显示：

```
Video stream: 3840x2160 60.49 FPS (Codec: HEVC)
Incoming frame rate from network: 60.49 FPS
Frames dropped by your network connection: 0.00%
Average network latency: 1 ms (variance: 0 ms)
```

## 原因 B：主机在 `resume`，沿用旧规格

改完设置重连还是 1080p？看请求路径：

```
.../resume?uniqueid=...&appid=881448767&mode=3840x2160...   # resume
.../launch?uniqueid=...&appid=881448767&mode=3840x2160x60   # launch（全新）
```

Sunshine 的 **"Desktop" 应用会话是常驻的**，客户端重连会走 `resume`，并沿用会话原本的编码规格 ——
于是你在客户端做的一切改动都被忽略 ✗

**解法：先结束会话，再全新 launch。**

```bash
# 用客户端自己的证书调用主机的 /cancel 接口
curl -sk --cert /path/to/client.crt --key /path/to/client.key \
  "https://<HOST>:47984/cancel?uniqueid=<CLIENT_UID>&uuid=<32位hex>"
# 成功返回：<root status_code="200"><cancel>1</cancel></root>
```

随后重新进入应用列表点 `Desktop`，这次日志里就是 `launch` + 目标规格 ✅

> 客户端 UID 在它自己的配置里（`uniqueid=...`）；证书/私钥同样从配置里导出（见 `01` 里的 Python 片段）。
> 想长期避免这个问题：让"回到省电模式"的脚本负责 `/cancel`，这样下一次进入必然是全新 launch。

## 原因 C：电视 HDMI 口没开「增强格式」

很多电视的 HDMI 口默认是"标准格式"，**只给 4K30**。切到「增强格式 / Enhanced format / HDMI 2.0+」后才会出 4K60。

判据（在客户端上看 EDID 支持的时序）：

```bash
cat /sys/class/drm/card*-HDMI-A-1/edid > /opt/edid.bin
# 或者直接在 X 里看可用模式
DISPLAY=:0 xrandr | grep -A2 "HDMI-A-0 connected"
```

`xrandr` 里出现 `3840x2160  60.00` 才算真支持。

## 附：让它自动重连

等电视/网络抖动后不必人工介入，给直连分支套一个循环：

```bash
while true; do
  "$MOONLIGHT" stream "$MOON_HOST" "$MOON_APP" \
    --display-mode fullscreen "--${MOON_RES}" --fps "$MOON_FPS" \
    --bitrate "$MOON_BITRATE" --audio-config stereo >>/tmp/moonlight.log 2>&1
  echo "[kiosk] $(date +%H:%M:%S) 串流结束，5 秒后重连..."; sleep 5
done
```

同时确保配置目录的 `export XDG_CONFIG_HOME=...` 放在**这个分支之前**，
否则 CLI 会用另一个未配对的配置目录启动（日志会写 `Computer ... has not been paired`）。
