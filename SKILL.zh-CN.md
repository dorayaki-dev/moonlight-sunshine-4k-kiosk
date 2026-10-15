---
name: moonlight-sunshine-4k-kiosk
description: 用于搭建或排查「Linux 客户端 + Moonlight 串流 Sunshine 主机到电视」—— 特别是 4K60 输出、配对报 401 证书不匹配、HDMI 无声音、手柄配对、以及待机功耗/风扇异常。把一台 Debian 系机器变成开机即串流、自动重连的全屏 kiosk。
license: MIT
---

# Moonlight → Sunshine 4K 电视 Kiosk

把一台 Linux 机器变成电视用的**全屏 4K60 Moonlight 客户端**，串流局域网里的 Sunshine 主机。

本 skill 本质上是一个**排障 skill**：搭起来不难，难的是**诊断**。下面每一条"坑"都有个共同特征 ——
**报错信息指向的地方，都不是真正的原因。**

## 何时使用

- 把一台 Linux 机器做成专用的电视串流客户端（全屏 kiosk、HDMI 输出、不需要桌面交互）
- 排查以下任一症状：
  - 配对报 `GeForce Experience returned error: Server certificate mismatch (Error 401)`
  - 4K 电视上串流只有 1080p
  - 有音频数据在流，但电视是哑的
  - Xbox 无线接收器 / 手柄 完全识别不到
  - 配好串流后，待机功耗或风扇噪音无故升高
- **不适用**：Windows 客户端、Android/TV 上的 Moonlight App、纯主机端（Sunshine）调优。

## 前置条件

- **客户端**：Debian 系 Linux，有 HDMI 输出；4K60 强烈建议**有线千兆**
- **主机**：游戏 PC 上装 [Sunshine](https://github.com/LizardByte/Sunshine)（任意近期版本）
- **电视**：HDMI 输入需开启「增强格式 / Enhanced format」，否则 4K 被限制在 30Hz
- 依赖包：`curl bsdtar alsa-utils imagemagick xdotool dkms git`
- 可选：Xbox 无线接收器（`045e:02fe` / `02e6` / `02f9` / `091e`）或任意 SDL 支持的手柄

## 执行步骤

### 1. 找到主机，确认初始状态干净

```bash
curl -s "http://<HOST>:47989/serverinfo?uniqueid=0123456789ABCDEF&uuid=$(cat /proc/sys/kernel/random/uuid | tr -d -)" \
  | tr '<' '\n' | grep -E 'hostname|PairStatus|HttpsPort'
```

应看到主机名和 `PairStatus 0`（未配对）。

- 如果电视上**同一台机器出现两个图标** → 主机上跑了**两个 Sunshine 实例**，先解决它
  （两个实例各有各的证书，会精确制造下面那个 401）。
- 对比 `:47989` 与 `:47984` 上返回的证书，必须一致。

### 2. 配对 —— 真正的修法是「让客户端信任主机的自签证书」

Sunshine 用的是自签名证书。Moonlight（Qt）在**配对的最后一步 TLS 校验**里验证它，失败就直接中断握手 ——
对外表现就是 `Server certificate mismatch (401)`。把主机证书装进客户端信任库即可：

```bash
echo | openssl s_client -connect <HOST>:47984 -showcerts 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/sunshine.crt
sudo cp /tmp/sunshine.crt /usr/local/share/ca-certificates/sunshine-host.crt
sudo update-ca-certificates

# 验证：严格校验必须通过
echo | openssl s_client -connect <HOST>:47984 -verify_return_error 2>&1 | grep "Verify return code"   # 期望 0 (ok)
```

同时在 kiosk 服务里钉住信任路径（AppImage 自带 OpenSSL，未必读系统默认）：

```ini
# /etc/systemd/system/moonlight.service.d/ssl.conf
[Service]
Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
Environment=SSL_CERT_DIR=/etc/ssl/certs
```

然后从电视配对：kiosk 上会显示一个**4 位 PIN** → 到 Sunshine Web UI（`https://<HOST>:47990`）
填 PIN + 设备名 → **发送**。

> **不要**用「重置客户端身份」「删主机端 `sunshine_state.json`」「重装 Sunshine」「找重复实例」去治这个 401 ——
> 这三个是最流行的"已知修法"，但**全都无效**。完整证据链见 `references/01-pairing-401-certificate.md`。

### 3. 强制 4K60 —— GUI 做不到

Moonlight 的 GUI **默认请求 1080p**，而且手改 `Moonlight.conf` 里的 `width`/`height`/`fps`/`bitrate`
会被程序**覆盖掉**。改用命令行直连模式：

```bash
"$MOONLIGHT" stream <HOST> Desktop \
  --display-mode fullscreen --4K --fps 60 --bitrate 60000 --audio-config stereo
```

在客户端日志里验证：

```
launch?...&mode=3840x2160x60      # 我们向主机请求的规格
SDL Info: Video stream is 3840x2160x60
```

电视上按 **Ctrl+Alt+Shift+S** 可调出性能浮层，直接看 `Video stream: 3840x2160 60 FPS` 与延迟/丢帧 —— 最快的真相来源。

如果日志仍是 `1920x1080`，说明主机在 **resume** 一个已存在的会话（常驻的 "Desktop" 应用会沿用旧规格）。
先结束会话再全新启动：

```bash
curl -sk --cert /path/client.crt --key /path/client.key \
  "https://<HOST>:47984/cancel?uniqueid=<CLIENT_UID>&uuid=<32位hex>"     # → <cancel>1</cancel>
```

### 4. 音频 —— 两种互不相干的故障

```bash
aplay -l | grep -i HDMI                  # 找 HDMI 的 PCM，例如 "card 2 ... device 3: HDMI 0"
speaker-test -D hw:<card>,<dev> -c 2 -t sine -l 1     # 电视到底响不响？
amixer -c <card> sget IEC958             # ← 电视没声的元凶常在这： "Mono: Playback [off]"
amixer -c <card> sset IEC958 on && amixer -c <card> sset IEC958 unmute
alsactl store
```

然后让 kiosk 指向这个设备：导出 `AUDIODEV=hw:<card>,<dev>`，**并且**写 `/etc/asound.conf`
把 `pcm.!default` / `ctl.!default` 指过去（见 `scripts/hdmi-audio.sh`，它每次启动重新探测，
因为声卡序号重启后会漂移）。

健康的日志：`Audio stream has 2 channels`、`Received first audio packet after … ms`，
且**没有** `Failed to open audio device`。

> 如果日志完美但电视依旧无声，几乎总是那个 `IEC958` 开关 —— 不是主机、不是流、也不是主机端的虚拟声卡。

### 5. 手柄

**先确认客户端到底有没有参与。** 手柄可能直接连在**主机**上（延迟更低：少一跳）：

```bash
# 在客户端上（若它有 Xbox 无线接收器）：
cat /sys/bus/usb/devices/*/active_clients 2>/dev/null      # "Active clients: 0" → 它上面没有任何手柄
grep -ciE "xbox|gamepad" /proc/bus/input/devices           # 0 → 客户端完全没看到手柄
```

若确实要由客户端接管手柄：Xbox 无线接收器需要 `xone` 驱动（DKMS）+ **固件** + **子模块** ——
**子模块才是真正创建设备的那一环**：

```bash
git clone --depth 1 https://github.com/dlundqvist/xone /usr/local/src/xone
cd /usr/local/src/xone && sudo ./install.sh --skip-disclaimer
sudo ./install/firmware.sh --skip-disclaimer          # 下载 xone_dongle_<PID>.bin
sudo modprobe xone_dongle
for m in xone_gip_gamepad xone_gip_chatpad xone_gip_headset; do sudo modprobe $m; done
ls /dev/input/js* ; grep -i xbox /proc/bus/input/devices
```

完整细节（配对按键、`Active clients`、固件 PID 对应、蓝牙替代方案）见 `references/04-controller-xone.md`。

### 6. 功耗与噪音 —— 最容易漏掉的一步

串流相关的"性能优化"经常把机器永久留在一个高功耗状态：

```bash
# 待机 / 省电模式：
for d in /sys/class/drm/card*/device/; do
  [ -w "$d/power_dpm_state" ] && echo battery > "$d/power_dpm_state"   # iGPU 可能被留在 performance（实测差 4W！）
  [ -w "$d/power/control" ]   && echo auto    > "$d/power/control"
done
echo 1 | sudo tee /sys/class/graphics/fb0/blank        # 消隐帧缓冲控制台

# 串流 / 游戏模式：反过来（performance / on / blank=0）
```

如果平台暴露风扇曲线，把它调成合理的（很多笔记本出厂曲线激进得离谱）：

```bash
# ASUS 示例：/sys/class/hwmon/*/name == "asus_custom_fan_curve"
# 安静曲线：50°C 以下停转，58°C 约 11%，95°C 满速
```

**务必把风扇曲线和 GPU 电源状态放进同一个模式切换脚本**，否则它们迟早会各自漂移。

## 验收清单

- [ ] 客户端日志出现 `Video stream is 3840x2160x60`（或电视浮层显示同规格）
- [ ] 音频：日志 0 错误 **且** 电视确实出声（`speaker-test … -t sine`）
- [ ] 手柄输入真的到达了被串流的游戏
- [ ] `Frames dropped by your network connection: 0.00%`，网络延迟 < 5 ms
- [ ] 切回省电模式后：待机功耗回到基线、风扇安静、GPU `power_dpm_state=battery`

## 陷阱速查

| 陷阱 | 正确做法 |
|---|---|
| `systemctl restart <kiosk>.service` 卡在 X 会话停止上（可能把 SSH 一起卡死）| `systemctl kill -s TERM` → `systemctl reset-failed` → `systemctl start` |
| `pkill -f "kiosk-script"` 会**匹配到你自己的 ssh 命令行**并把自己杀掉 | 用 `pkill -f "[k]iosk-script"`，或直接 `systemctl kill` |
| AppImage 的进程名是 `…/squashfs-root/usr/bin/moonlight`，**不是** AppRun | 按真实二进制路径匹配 |
| 客户端输出进了 tty，`journalctl` 里什么都没有 | 启动前加 `exec 2>>/tmp/moonlight.log` |
| 命令行直连分支用的配置目录与已配对的那份不一致 | 把配置目录的 export 放在**直连分支之前**（否则 CLI 会以未配对身份运行：`Computer … has not been paired`）|
| 主机端网络变化后客户端缓存了旧 IP | 优先用 mDNS/`.local` 名字，或刷新主机记录 |
| 串流结束后待机功耗比之前高 | 就是 iGPU 的 `power_dpm_state` —— 见第 6 步 |

## 为什么会有这个 skill

一晚上端到端搭通并排查完。那个 401 被误诊了三次（"重置客户端身份""删 `sunshine_state.json`""你有两个 Sunshine 实例"），
直到用**同一张客户端证书**做了一次裸 `openssl s_client` 握手并成功 —— 这才证明证书没问题，
失败发生在客户端的**证书校验**环节，而不是配对状态。上表每一条都是这类陷阱：**报错指向的地方，不是原因所在。**
