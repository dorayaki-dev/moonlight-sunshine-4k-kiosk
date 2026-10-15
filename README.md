# 🎮 moonlight-sunshine-4k-kiosk

> 把一台 Linux 机器变成「客厅电视上的 4K60 Moonlight 串流客户端」的 Agent Skill —— 并附带一整套**排障树**。
>
> An Agent Skill that turns a Linux box into a **4K60 Moonlight kiosk for your TV** — shipping with the full troubleshooting tree.

[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-SKILL.md-blue)](https://agentskills.io)
[![4K60](https://img.shields.io/badge/verified-4K60%20%2B%20audio-success)](#-实测数据--measured-results)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## 为什么做这个 · Why this exists

在客厅电视上用 Moonlight 串流 PC 游戏，看起来只是"装个客户端、配个对"——但真正动手时，你会撞上一串**官方文档里完全没有、GitHub issue 里全是瞎猜**的墙：

设置能跑通，**排障知识才是稀缺品**。这个 skill 沉淀的不是"怎么装 Moonlight"（那个官网有），而是：

> **症状 → 真正原因 → 一行命令验证 → 修法**

*Setting it up is the easy part. **Diagnosing it is where everyone gets stuck.** This skill carries the diagnosis, not the install guide.*

### 症状对照表 · Symptom → Root cause → Fix

| 症状 Symptom | 真正原因 Root cause | 修法 Fix | 详情 |
|---|---|---|---|
| 配对报 `Server certificate mismatch (Error 401)` | Moonlight(Qt6) 在配对最后一步校验服务端**自签证书**失败 → 直接掐断 TLS 握手（日志：`SslHandshakeFailedError`）。换客户端身份 / 删服务端状态 / 重装服务端**都没用** ✗ | 把服务端证书装进**客户端信任库** | [01](references/01-pairing-401-certificate.md) |
| 4K 电视上画面发糊，只有 1080p | Moonlight GUI 默认请求 1080p；手改 `Moonlight.conf` 的 `width/height` 会被程序覆盖 ✗ | 改用**命令行直连**：`--4K --fps 60` | [02](references/02-4k-and-resume.md) |
| 改了 4K 设置，重连还是 1080p | Sunshine 的桌面会话常驻，重连走 `resume` 会沿用旧规格 | 先 `/cancel` 结束会话，再全新 `launch` | [02](references/02-4k-and-resume.md) |
| 串流有声音数据，但电视是哑的 | 客户端 ALSA 的 HDMI 输出被**静音**了：`IEC958 Playback [off]`（数据在流、开关关着）| `amixer -c <card> sset IEC958 on` + `alsactl store` | [03](references/03-audio-hdmi.md) |
| 日志报 `Failed to open audio device: No such file or directory` | 没指定 HDMI 声卡，ALSA 找不到默认设备 | 动态探测 HDMI 设备 → `AUDIODEV` + `/etc/asound.conf` | [03](references/03-audio-hdmi.md) |
| Xbox 无线接收器插上毫无反应 | Linux 需要 `xone` 驱动 + **固件** + **子模块**（子模块不加载就不会生成手柄设备）| DKMS 安装 + `install/firmware.sh` + 加载全部子模块 | [04](references/04-controller-xone.md) |
| 串流结束后待机功耗涨了 4W | iGPU 的 `power_dpm_state` 被留在 `performance`，不串流也把显存钉在最高频 | 模式切换时回收成 `battery` | [05](references/05-power-tuning.md) |
| 待机 3400 RPM 很吵，而 CPU 才 40°C | 风扇曲线过激（40°C 就起转）| 50°C 以下停转的安静曲线 | [05](references/05-power-tuning.md) |

---

## 架构 · Architecture

```
   ┌──────────────────────┐                    ┌───────────────────────────┐
   │  Windows / Linux PC  │   LAN (≥100Mbps)   │        Linux kiosk        │
   │  ─────────────────   │ ═════════════════▶ │  ──────────────────────   │
   │  Sunshine (host)     │   HEVC 4K60 视频   │  Moonlight (client)       │
   │  · NVENC/AMF 编码    │   + 音频 + 输入    │  · VAAPI 硬解             │
   │  · 音频：虚拟声卡    │                    │  · 全屏 kiosk（xinit）    │
   │    (VB-CABLE)        │                    │  · HDMI → 电视            │
   └──────────────────────┘                    └────────────┬──────────────┘
                                                            │ HDMI 2.0 (4K60)
                                                            ▼
                                                   ┌──────────────────┐
                                                   │   电视 / TV      │
                                                   │  HDMI"增强格式"  │
                                                   └──────────────────┘

   客户端三件事：① 配对（TLS 信任）② 请求 4K60（命令行直连）③ 输出（HDMI 音视频）
   The client does three things: pair (TLS trust) → request 4K60 (CLI direct mode) → output (HDMI A/V)
```

---

## 快速开始 · Quick start

### 作为 Agent Skill 安装 · Install as a skill

```bash
# 通用（自动识别 Claude Code / Cursor / Codex / Hermes 等）
npx skills add Swagzhp/moonlight-sunshine-4k-kiosk

# 或手动：把本目录拷进你 agent 的 skills 目录
cp -R moonlight-sunshine-4k-kiosk ~/.claude/skills/
```

然后对你的 agent 说 / then ask your agent：

> "帮我把这台 Linux 机器配成电视上 4K60 的 Moonlight 客户端"
> *"Set this Linux box up as a 4K60 Moonlight client for my TV."*

### 前置条件 · Prerequisites

- **客户端**：Linux（Debian/Ubuntu 系已实测），有 HDMI 输出；**推荐有线千兆**
- **服务端**：Windows/Linux + [Sunshine](https://github.com/LizardByte/Sunshine)（任意近期版本）
- **电视**：HDMI 口需开启「增强格式 / Enhanced format」否则只给 4K30
- 可选：Xbox 无线接收器（走 `xone`）或任意 SDL 支持的手柄

---

## 实测数据 · Measured results

在「fnOS(Debian 12) + AMD 核显 + 有线千兆」的客户端上（4K60 串流中，Moonlight 性能浮层实测）：

```
Video stream: 3840x2160   60.49 FPS   (HEVC)
渲染帧率 60.00 FPS · 网络丢帧 0.00% · 网络延迟 1 ms
平均解码 43 ms · 主机处理延迟 ~14 ms
音频：ALSA HDMI 输出，错误 0 条
待机（NAS 模式）：9 W · 风扇 0 RPM · CPU/GPU ~45°C
```

---

## 仓库结构 · What's inside

```
moonlight-sunshine-4k-kiosk/
├── SKILL.md                              # Agent 执行流程（英文；中文版 SKILL.zh-CN.md）
├── SKILL.zh-CN.md                        # 中文版
├── references/
│   ├── 01-pairing-401-certificate.md     # 401 证书不匹配：完整证据链与修法
│   ├── 02-4k-and-resume.md               # 4K 不生效 / resume vs launch / /cancel
│   ├── 03-audio-hdmi.md                  # 无声音：设备探测 + IEC958 静音
│   ├── 04-controller-xone.md             # Xbox 无线小棒：xone 驱动 + 固件 + 子模块
│   ├── 05-power-tuning.md                # 待机功耗与风扇曲线
│   └── troubleshooting-decision-tree.md  # 症状 → 原因 决策树（总入口）
├── scripts/
│   ├── mode.sh                           # 模式切换：nas / stream / game / stop-stream
│   ├── moonlight-kiosk.sh                # kiosk 启动脚本（含音频探测、自动重连）
│   ├── moonlight.service                 # systemd 单元
│   ├── hdmi-audio.sh                     # HDMI 音频自动探测 + 取消静音
│   └── fan.sh                            # ASUS 风扇曲线（quiet / cool / auto）
├── LICENSE                               # MIT
└── README.md
```

---

## 适用范围与边界 · Scope & limits

- ✅ 已在 **fnOS（Debian 12 基）+ AMD APU（VAAPI 解码）+ Sunshine** 组合上完整验证
- ⚠️ `scripts/fan.sh` 使用 ASUS 的 `asus_custom_fan_curve` 接口，**非 ASUS 机型请跳过**（其余部分通用）
- ⚠️ 4K120 / HDR 不在本项目范围（需要 HDMI 2.1 + 独显输出链路）
- 🔒 本仓库不含任何个人环境信息：所有 IP、主机名、设备名、路径均已占位符化（`<SUNSHINE_HOST>` 等）

---

## 许可 · License

[MIT](LICENSE) —— 随意使用、修改、商用。

## 致谢 · Credits

- [Sunshine](https://github.com/LizardByte/Sunshine) —— 开源串流主机端
- [Moonlight](https://github.com/moonlight-stream) —— 开源串流客户端
- [xone](https://github.com/dlundqvist/xone) —— Xbox 无线接收器 Linux 驱动
- 以及那些在 issue 区留下线索的人 ✍️
