# 04 · 手柄：先搞清楚它连在哪，再谈驱动

## 第一步永远是：客户端到底有没有参与？

手柄有两条完全不同的链路，延迟差很多：

```
A) 手柄 ──直连──▶ 主机（游戏本地读输入）        ← 延迟最低（少一到两跳）
B) 手柄 ──▶ 客户端 ──Moonlight 转发──▶ 主机    ← 多一跳
```

**不要假设**。三条命令就能判定（在客户端上跑）：

```bash
# 1) 客户端的 Xbox 无线接收器上连着手柄吗？（驱动自己报的）
cat /sys/bus/usb/devices/*/active_clients 2>/dev/null      # "Active clients: 0" → 没有

# 2) 客户端有没有手柄输入设备？
grep -ciE "xbox|gamepad" /proc/bus/input/devices            # 0 → 没有
ls /dev/input/js* 2>/dev/null                               # 空也可能是正常的（见下方注）

# 3) 客户端蓝牙里有手柄吗？
bluetoothctl devices | grep -i xbox
```

**最硬的判据是物理实验**：把手柄在客户端上的接收器**拔掉** —— 如果游戏里手柄照常能用，
那它连的是主机，客户端压根没参与 ✅（这是最快的结论，不用折腾任何驱动）

> 注：`/dev/input/js*` 需要加载 `joydev` 模块，现代系统常常没有它。**SDL/evdev 直接吃 `/dev/input/event*`
> 和 `/proc/bus/input/devices`**，所以别用 `js*` 的存在与否来判断手柄有没有被识别。

## 如果确实要让客户端接管：Xbox 无线接收器（xone）

### 识别硬件

```bash
lsusb | grep -i "045e"
# 045e:02fe  Xbox Wireless Adapter for Windows (model 1790)
# 045e:02e6 / 02f9 / 091e  其它型号
```

Linux 需要 **`xone`** 驱动（`xpad` 管不了这些无线小棒 ✗）。检查内核有没有：

```bash
modinfo xone 2>/dev/null || echo "内核里没有，需要 DKMS 编译"
# 编译前提：内核头文件必须存在
ls -d /lib/modules/$(uname -r)/build && echo "✅ 可以编译" || echo "❌ 厂商精简内核，缺头文件，先补内核头"
```

### 安装（DKMS）

```bash
sudo apt-get install -y dkms curl libarchive-tools git
git clone --depth 1 https://github.com/dlundqvist/xone /usr/local/src/xone
cd /usr/local/src/xone
sudo ./install.sh --skip-disclaimer          # DKMS 编译安装全部模块
sudo ./install/firmware.sh --skip-disclaimer # 下载 xone_dongle_<PID>.bin 固件
```

`install.sh` 会顺带把 `xpad` 加入黑名单（避免抢设备）—— 这是正常的，**有线** Xbox 手柄由 `xone_wired` 接管。

### ★ 最容易漏的一步：加载所有子模块

`xone` 是**多模块**结构，**子模块才是真正创建手柄设备的那一环**。只 `modprobe xone_dongle`
会出现"驱动绑上了、`active_clients` 也有反应，但就是没有手柄设备" ✗

```bash
sudo modprobe xone_dongle
for m in xone_gip_gamepad xone_gip_chatpad xone_gip_headset \
         xone_gip_madcatz_glam xone_gip_madcatz_strat xone_gip_pdp_jaguar; do
  sudo modprobe "$m" 2>/dev/null && echo "✅ $m"
done
```

开机自加载（子模块不会自己加载，要显式列上）：

```bash
# /etc/modules-load.d/xone.conf
xone_dongle
xone_gip
xone_gip_gamepad
xone_gip_chatpad
xone_gip_headset
```

### 让手柄和小棒配对

小棒和手柄的配对**和游戏机/Windows 一样是硬件行为**，Linux 不提供软件 UI：

1. 按小棒上的**同步/配对按钮**（旁边通常有指示灯）→ 灯开始**闪烁**
2. 长按**手柄顶部的配对键**（USB-C 口旁边）约 3 秒 → 直到 Xbox 键**快速闪烁**
3. 几秒内自动配上（小棒灯变常亮）

注意：**手柄一次只记住一个 Xbox 无线主机**。把它配到客户端的小棒上，就等于"忘记"主机上的那个。

### 验证

```bash
grep -i xbox /proc/bus/input/devices          # 应出现手柄设备
for p in /sys/class/power_supply/*/; do [ -f "$p/capacity" ] && echo "$(basename $p): $(cat $p/capacity)%"; done
# 手柄电量会作为 power_supply 出现（xone 的特性）
dmesg | grep -i xone | tail
```

Moonlight 通过 SDL 热插拔识别手柄；若游戏里没反应，重启一次 kiosk 服务即可。

## 常见坑

| 现象 | 原因 / 处理 |
|---|---|
| `xone_dongle_fw_load: load firmware failed: -110` | 固件上传 USB 超时（小棒状态不干净）→ **拔下小棒等 3 秒再插回**（比重启省事） |
| `modprobe xone` 失败：`Module not found` | 模块名不是 `xone` 而是 `xone_dongle` / `xone_gip` / `xone_gip_*` |
| `rmmod` 报 `Module xone_gip is in use by xone_dongle` | 卸载顺序反了：先 `rmmod xone_dongle`，再 `xone_gip` |
| 重新插拔后驱动没接管 | `readlink -f /sys/bus/usb/devices/*/driver` 看**接口**（`3-1:1.0`）而不是 USB 设备节点 |
| 判定"驱动没绑上" | USB **设备**节点的 driver 永远是 `usb`，要看**接口**节点 |
| 装了驱动 / 插了接收器，功耗涨了 | 不用就拔掉；`xone` 驱动本身空闲不耗电，是**硬件**在耗 |

## 蓝牙作为替代方案（延迟更高）

手柄（如 Xbox Elite 2）也支持蓝牙，`bluetoothctl` 即可配对，但：

- 延迟高于 Xbox 无线协议（串流游戏能感觉到）
- 需要在客户端装 `bluez`，且 BLE HID 依赖内核 `uhid` + 正确完成 **bonding**（`Paired: yes` 才算数；
  只有 `Connected: yes` 是**不够**的，此时不会生成输入设备）
- Xbox 手柄在 Linux 蓝牙下建议搭配 **`xpadneo`** 驱动（DKMS）

**结论**：能直连主机就直连；必须走客户端时优先 Xbox 无线小棒 + `xone`，蓝牙只作兜底。
