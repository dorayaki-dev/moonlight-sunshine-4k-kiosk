# 03 · 电视没有声音：两种互不相干的故障

> 这个坑最气人，因为**日志看上去一切正常**：音频数据在流、解码正常、声卡在 RUNNING —— 但电视就是哑的。

## 先分诊：数据有没有到客户端？

在客户端日志里找这三行：

```bash
grep -iE "audio" /tmp/moonlight.log | tail
```

```
SDL Info: SDL audio driver: alsa
SDL Info: Audio stream has 2 channels
SDL Info: Received first audio packet after 500 ms
```

- **有 `Received first audio packet`** → 主机端一切正常（流里带着音频），问题 100% 在**客户端的输出环节** → 看下面
- **完全没有音频相关行** → 主机没有采集到音频（Windows 主机需把音频输出接到虚拟声卡，如 VB-CABLE；
  客户端侧先放一边）

> 顺带一提：**主机端设置对不对，看客户端日志就能判断**，不必去主机上折腾。

## 故障 A：ALSA 打不开设备

```
SDL Error (0): Failed to open audio device: ALSA: Couldn't open audio device: No such file or directory
Qt Warning: Failed to open audio device. Audio will be unavailable during this session.
```

原因：没指定 HDMI 声卡，系统里没有可用的默认 PCM。

```bash
aplay -l | grep -i HDMI
# card 2: Generic [HD-Audio Generic], device 3: HDMI 0 [<YOUR TV>]
#        ↑ card 号                   ↑ device 号
```

自测设备本身能不能出声（这一步能排除"电视音量/输入源"的问题）：

```bash
speaker-test -D hw:2,3 -c 2 -t sine -f 440 -l 1     # 电视应发出 1 秒 440Hz
```

⚠️ **注意**：卡号（card 2/3…）**重启后会漂移**，别写死。两种做法都要：

1. 给 SDL 指定设备：`export AUDIODEV=hw:<card>,<dev>`
2. 写全局 ALSA 默认（SDL 万一不认 `AUDIODEV` 的兜底）：

```conf
# /etc/asound.conf
pcm.!default { type hw; card <card>; device <dev> }
ctl.!default { type hw; card <card>; device <dev> }
```

把探测逻辑放进 kiosk 启动脚本（`scripts/hdmi-audio.sh` 可以直接用）：

```bash
HDMI_LINE=$(aplay -l 2>/dev/null | grep -m1 -i "HDMI")
if [ -n "$HDMI_LINE" ]; then
  A_CARD=$(echo "$HDMI_LINE" | grep -oE "^card [0-9]+"    | grep -oE "[0-9]+")
  A_DEV=$(echo  "$HDMI_LINE" | grep -oE "device [0-9]+"   | grep -oE "[0-9]+")
  export AUDIODEV="hw:${A_CARD},${A_DEV}"
  printf 'pcm.!default { type hw; card %s; device %s }\nctl.!default { type hw; card %s; device %s }\n' \
    "$A_CARD" "$A_DEV" "$A_CARD" "$A_DEV" > /etc/asound.conf
fi
```

## 故障 B：设备正常，但 HDMI 输出被静音 ★ 最隐蔽

数据在流、声卡 `RUNNING`、`speaker-test` 也响 —— 但 Moonlight 播放时就是没声。
**先查这一行**：

```bash
amixer -c <card> sget IEC958
```

```
Simple mixer control 'IEC958',0
  Playback channels: Mono
  Mono: Playback [off]        ← ★ 就是它
```

修复并持久化：

```bash
amixer -c <card> sset IEC958 on
amixer -c <card> sset IEC958 unmute
alsactl store            # 重启后保持
```

同时**在 kiosk 启动脚本里每次启动都设一遍** —— 显示模式切换、设备重枚举都可能把它关回去：

```bash
amixer -c "${A_CARD}" sset "IEC958" on     >/dev/null 2>&1
amixer -c "${A_CARD}" sset "IEC958" unmute >/dev/null 2>&1
```

## 验证闭环

```bash
# 1) 声卡是否真的在播（RUNNING = 正在输出）
cat /proc/asound/card<card>/pcm<dev>p/sub0/status      # state: RUNNING

# 2) 日志里 0 条音频错误
grep -c "Failed to open audio" /tmp/moonlight.log      # 期望 0

# 3) 混音开关是开的
amixer -c <card> sget IEC958 | grep Mono               # Playback [on]

# 4) 电视真的出声（最终判据，人耳）
```

## 排查顺序建议（照着走，别跳）

```
电视无声
 ├─ 日志里有 "Received first audio packet" 吗？
 │   ├─ 没有 → 主机端没采到音频（虚拟声卡/默认输出设备）→ 去主机端
 │   └─ 有   ↓
 ├─ 日志里有 "Failed to open audio device" 吗？
 │   ├─ 有 → 故障 A：设备探测 + AUDIODEV + /etc/asound.conf
 │   └─ 没有 ↓
 ├─ amixer 的 IEC958 是 [off] 吗？
 │   ├─ 是 → 故障 B：打开它（★ 本坑最常见的真凶）
 │   └─ 不是 ↓
 └─ 电视侧：音量 / 音频输出源（内置扬声器 vs ARC/外接音响）/ HDMI 输入口
```
