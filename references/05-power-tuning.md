# 05 · 待机功耗与风扇：串流留下的"隐形账单"

> 这类问题没人会主动排查 —— 直到电费或噪音受不了。**它们通常是同一个原因：为了串流做的"性能优化"没有回收。**

## 实测案例

```
串流做完、切回省电模式后：
  待机功耗 14 W，风扇却 0 RPM、CPU/GPU 只有 40 °C   ← 明显不对

逐项排查后定位：
  power_dpm_state = performance     ← iGPU 被钉在最高功耗态（显存 1600MHz 一直跑）
  power/control   = on              ← 运行时休眠被禁止
  fb0/blank       = 0               ← 帧缓冲控制台没消隐

修复后：10 W → 9 W（省 4~5 W，回到基线）
```

## 一、iGPU 电源状态（最常见的隐形耗电）

AMD 核显（`amdgpu`）通过 sysfs 暴露功耗档位。**为串流流畅把它设成 `performance` 后，如果没人回收，
它会一直生效** —— 哪怕你根本没在串流：

```bash
D=/sys/class/drm/card1/device       # 用 ls 找到真正有 power_dpm_state 的那个 card

cat $D/power_dpm_state              # battery | balanced | performance
cat $D/pp_dpm_mclk | grep '\*'      # 当前显存频率（performance 下通常顶在最高）
cat $D/power/control                # on = 禁止休眠，auto = 允许
cat $D/power/runtime_status
```

**省电模式：**

```bash
for d in /sys/class/drm/card*/device/; do
  [ -w "$d/power_dpm_state" ] && echo battery > "$d/power_dpm_state"
  [ -w "$d/power/control" ]   && echo auto    > "$d/power/control"
done
echo 1 | sudo tee /sys/class/graphics/fb0/blank    # 消隐帧缓冲控制台（headless 机器上它会把 GPU 钉醒）
```

**串流 / 游戏模式（反向）：** `performance` + `on` + `fb0/blank=0`。

> 必须**成对写进同一个模式切换脚本**（见 `scripts/mode.sh`），否则这就是个定时炸弹。

## 二、风扇曲线（噪音）

很多笔记本出厂（或厂商工具设的）曲线极其激进：**40 °C 就起转**，待机也能吹出 3400 RPM ✗

先看平台有没有暴露可写的曲线。ASUS 机型在 hwmon 里：

```bash
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat $h/name 2>/dev/null)" = "asus_custom_fan_curve" ] && echo "$h"
done
```

实测可用的**安静曲线**（8 个温度点 + 对应占空比 0~255）：

| 温度 | 50 °C | 58 °C | 64 °C | 70 °C | 76 °C | 82 °C | 88 °C | 95 °C |
|---|---|---|---|---|---|---|---|---|
| 占空比 | 0 | 30 | 70 | 110 | 150 | 190 | 230 | 255 |
| 比例 | 0% | 11% | 27% | 43% | 58% | 74% | 90% | 100% |

写入方式（`pwmN_auto_pointM_temp` / `_pwm`，最后置 `pwmN_enable=1` 表示使用自定义曲线）：

```bash
C=/sys/class/hwmon/hwmonX      # name = asus_custom_fan_curve
temps="50 58 64 70 76 82 88 95"; pwms="0 30 70 110 150 190 230 255"
i=1
for t in $temps; do
  p=$(echo $pwms | cut -d' ' -f$i)
  for f in 1 2; do
    echo "$t" > "$C/pwm${f}_auto_point${i}_temp"
    echo "$p" > "$C/pwm${f}_auto_point${i}_pwm"
  done
  i=$((i+1))
done
for f in 1 2; do echo 1 > "$C/pwm${f}_enable"; done   # 1 = 自定义曲线；2 = 交还 EC 自动
```

- **安全兜底**：88 °C 起就 90%、95 °C 满速 —— 为了安静烧机器不值得
- **开机自动套用**：写成 oneshot systemd 服务（`After=multi-user.target`）
- 其它品牌：找各自的风扇接口（`nbfc`、`thinkfan`、`platform_profile` 等），思路一致

## 三、其它小项（逐个关掉，累计可观）

| 项目 | 检查 | 说明 |
|---|---|---|
| PCIe ASPM | `cat /proc/cmdline \| grep aspm`；内核参数 `pcie_aspm.policy=powersave` | 实测让 L1 省电设备从 4 → 10 个 |
| 无线网卡 | `cat /sys/class/net/wlp*/operstate` | 有线环境下 `down` 更省 |
| 蓝牙 | `systemctl disable --now bluetooth` | 不用就关 |
| 独显 | `lspci \| grep -i nvidia`，或 `/sys/bus/pci/devices/*/power/runtime_status` | 纯串流客户端应保持断电 |
| USB 外设 | `cat /sys/bus/usb/devices/*/power/runtime_status` | 无线键鼠接收器约 0.3 W，需要用就留着 |
| 内屏背光 | `/sys/class/backlight/*/{brightness,bl_power}` | 合盖/关屏后 `bl_power=0`、`brightness=0` |

## 四、测量方法（否则会白折腾）

- 用**带计量的智能插座**，别指望软件估算
- 这类插座**读数粗（1 W 步进）、刷新慢（十几秒）**，所以：**每次改动后至少采样 3 次、间隔 20~30 秒再看**
- 一次只改一项，改完再采样 —— 否则无法归因

```bash
# 一次采样示例（HA 环境）
# sensor.<plug>_electric_power
```

## 五、一句话总结

> **凡是"为了性能临时打开"的开关（GPU 档位、风扇曲线、ASPM、服务），都要在同一个模式切换脚本里
> 成对处理 —— 否则它一定会在某个夜晚悄悄吃掉 4 W 或多吹 3400 RPM。**
