---
name: moonlight-sunshine-4k-kiosk
description: Use when setting up or debugging a Linux Moonlight client that streams a Sunshine host to a TV — especially 4K60 output, pairing failures (401 "Server certificate mismatch"), missing HDMI audio, gamepad pairing, or idle power/fan regressions. Turns a Debian-family box into a fullscreen kiosk that auto-starts the stream, forwards audio/video over HDMI, and self-recovers after disconnects.
license: MIT
---

# Moonlight → Sunshine 4K TV Kiosk

Turn a Linux machine into a fullscreen **4K60 Moonlight client** for a TV, streaming from a Sunshine host on the LAN.

This skill is mostly a **debugging skill**: setup is easy, diagnosis is where everyone gets stuck. Every "pitfall"
below is something that looks like a different problem than it is.

## When to use

- Building a dedicated TV streaming client out of a Linux box (kiosk, HDMI out, no desktop interaction needed)
- Debugging any of these symptoms:
  - pairing fails with `GeForce Experience returned error: Server certificate mismatch (Error 401)`
  - stream is stuck at 1080p on a 4K TV
  - audio data flows but the TV is silent
  - Xbox wireless dongle / gamepad is not detected
  - idle power draw or fan noise jumped after setting up streaming
- **Not** for: Windows clients, Moonlight apps on Android/TV devices, or pure server-side Sunshine tuning.

## Prerequisites

- **Client**: Debian-family Linux with an HDMI output; wired gigabit strongly recommended for 4K60
- **Host**: [Sunshine](https://github.com/LizardByte/Sunshine) (any recent version) on the gaming PC
- **TV**: HDMI input switched to "Enhanced format" / HDMI 2.0+ (otherwise 4K is capped at 30 Hz)
- Packages: `curl bsdtar alsa-utils imagemagick xdotool dkms git`
- Optional: Xbox Wireless Adapter (`045e:02fe` / `02e6` / `02f9` / `091e`) or any SDL-supported gamepad

## Procedure

### 1. Find the host and confirm a clean starting state

```bash
curl -s "http://<HOST>:47989/serverinfo?uniqueid=0123456789ABCDEF&uuid=$(cat /proc/sys/kernel/random/uuid | tr -d -)" \
  | tr '<' '\n' | grep -E 'hostname|PairStatus|HttpsPort'
```

Expect the hostname and `PairStatus 0` (unpaired).

- If the TV shows **two** host icons for one machine, **two Sunshine instances are running** on the host — fix that
  first (they serve different certificates and will produce exactly the 401 below).
- Compare the certificate served on `:47989` and `:47984`; they must be the same one.

### 2. Pair — the real fix is trusting the host's self-signed certificate

Sunshine uses a self-signed certificate. Moonlight (Qt) validates it during the **final TLS step of pairing** and,
when validation fails, aborts the handshake — which surfaces as `Server certificate mismatch (401)`.
Installing the host certificate into the client's trust store is the fix:

```bash
echo | openssl s_client -connect <HOST>:47984 -showcerts 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/sunshine.crt
sudo cp /tmp/sunshine.crt /usr/local/share/ca-certificates/sunshine-host.crt
sudo update-ca-certificates

# verify: strict verification must now succeed
echo | openssl s_client -connect <HOST>:47984 -verify_return_error 2>&1 | grep "Verify return code"   # expect: 0 (ok)
```

Also pin the trust paths in the kiosk service, because AppImages bundle their own OpenSSL:

```ini
# /etc/systemd/system/moonlight.service.d/ssl.conf
[Service]
Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
Environment=SSL_CERT_DIR=/etc/ssl/certs
```

Then pair from the TV: the kiosk shows a **4-digit PIN** → enter it in the Sunshine web UI
(`https://<HOST>:47990`) together with a device name → **Send**.

> **Do not** try to fix the 401 by resetting the client identity, deleting the host's `sunshine_state.json`,
> reinstalling Sunshine, or hunting for duplicate hosts. Those are the three popular "known fixes" and they all fail.
> See `references/01-pairing-401-certificate.md` for the full evidence chain.

### 3. Force 4K60 — the GUI will not do it

Moonlight's GUI requests **1080p by default**, and hand-editing `width`/`height`/`fps`/`bitrate` in
`Moonlight.conf` gets **overwritten** by the app. Use the CLI direct-stream mode instead:

```bash
"$MOONLIGHT" stream <HOST> Desktop \
  --display-mode fullscreen --4K --fps 60 --bitrate 60000 --audio-config stereo
```

Verify in the client log:

```
launch?...&mode=3840x2160x60      # what we asked the host for
SDL Info: Video stream is 3840x2160x60
```

On the TV you can press **Ctrl+Alt+Shift+S** to toggle a stats overlay showing
`Video stream: 3840x2160 60 FPS` plus latency/drops — the fastest ground truth.

If the log still shows `1920x1080`, the host is **resuming** an existing session (a resident "Desktop" app keeps its
original stream parameters). End it and launch fresh:

```bash
curl -sk --cert /path/client.crt --key /path/client.key \
  "https://<HOST>:47984/cancel?uniqueid=<CLIENT_UID>&uuid=<32-hex>"     # → <cancel>1</cancel>
```

### 4. Audio — two independent failure modes

```bash
aplay -l | grep -i HDMI                  # find the HDMI PCM, e.g. "card 2 ... device 3: HDMI 0"
speaker-test -D hw:<card>,<dev> -c 2 -t sine -l 1     # does the TV actually make sound?
amixer -c <card> sget IEC958             # ← the silent-TV trap: "Mono: Playback [off]"
amixer -c <card> sset IEC958 on && amixer -c <card> sset IEC958 unmute
alsactl store
```

Then make the kiosk point at that device: export `AUDIODEV=hw:<card>,<dev>` **and** write
`/etc/asound.conf` with `pcm.!default` / `ctl.!default` → the HDMI device (see `scripts/hdmi-audio.sh`, which
re-detects on every start because card indices drift across reboots).

Healthy log lines: `Audio stream has 2 channels`, `Received first audio packet after … ms`, and **no**
`Failed to open audio device`.

> If the log looks perfect and the TV is still silent, it is almost always the `IEC958` switch — not the host,
> not the stream, not VB-CABLE on the host side.

### 5. Controllers

**First, verify whether the client is even involved.** A controller may be connected directly to the *host*
(better latency: no extra hop):

```bash
# on the client, if it has an Xbox wireless dongle:
cat /sys/bus/usb/devices/*/active_clients 2>/dev/null      # "Active clients: 0" → nothing is connected to it
grep -ciE "xbox|gamepad" /proc/bus/input/devices           # 0 → the client sees no gamepad at all
```

If the client *is* meant to own the gamepad, Xbox Wireless Adapters need the `xone` driver (DKMS), its firmware,
**and its submodules** — the submodules are what actually create the input device:

```bash
git clone --depth 1 https://github.com/dlundqvist/xone /usr/local/src/xone
cd /usr/local/src/xone && sudo ./install.sh --skip-disclaimer
sudo ./install/firmware.sh --skip-disclaimer          # downloads xone_dongle_<PID>.bin
sudo modprobe xone_dongle
for m in xone_gip_gamepad xone_gip_chatpad xone_gip_headset; do sudo modprobe $m; done
ls /dev/input/js* ; grep -i xbox /proc/bus/input/devices
```

Full detail (pairing buttons, `Active clients`, firmware PIDs, the Bluetooth alternative) in `references/04-controller-xone.md`.

### 6. Power & noise — the part everyone forgets

Streaming tweaks often leave the machine in a high-power state **forever**:

```bash
# idle / power-save mode:
for d in /sys/class/drm/card*/device/; do
  [ -w "$d/power_dpm_state" ] && echo battery > "$d/power_dpm_state"   # iGPU: was left at "performance" (+4 W!)
  [ -w "$d/power/control" ]   && echo auto    > "$d/power/control"
done
echo 1 | sudo tee /sys/class/graphics/fb0/blank        # blank the framebuffer console

# streaming / game mode: reverse the above (performance / on / blank=0)
```

And if the platform exposes a fan curve, make it sane (many laptops ship aggressively loud curves):

```bash
# ASUS example: /sys/class/hwmon/*/name == "asus_custom_fan_curve"
# quiet curve: 0% below 50 °C, ~11% at 58 °C, 100% at 95 °C
```

Keep the fan curve **and** the GPU power state in the same mode-switch script so they can never drift apart again.

## Verification checklist

- [ ] `Video stream is 3840x2160x60` in the client log (or the Ctrl+Alt+Shift+S overlay on the TV)
- [ ] Audio: 0 errors in the log **and** a real sound out of the TV (`speaker-test … -t sine`)
- [ ] Controller input actually reaches the streamed game
- [ ] `Frames dropped by your network connection: 0.00%`, network latency < 5 ms
- [ ] After switching to power-save: idle power back at baseline, fans quiet, GPU `power_dpm_state=battery`

## Pitfalls (each one has bitten a real setup)

| Pitfall | What to do instead |
|---|---|
| `systemctl restart <kiosk>.service` hangs on the X session stop (can wedge SSH) | `systemctl kill -s TERM` → `systemctl reset-failed` → `systemctl start` |
| `pkill -f "kiosk-script"` **matches your own ssh command line** and kills your session | `pkill -f "[k]iosk-script"`, or just `systemctl kill` |
| AppImage process name is `…/squashfs-root/usr/bin/moonlight`, not `AppRun` | match on the real binary path when killing |
| Client output goes to a tty, so `journalctl` shows nothing | add `exec 2>>/tmp/moonlight.log` before launching the app |
| CLI direct-stream branch uses a different config dir than the paired GUI | export the config dir **before** the direct-stream branch (or the CLI runs unpaired: `Computer … has not been paired`) |
| Client cached a stale host IP after the host's network changed | prefer mDNS/`.local` names, or refresh the host entry |
| Post-stream idle power is higher than before | it is the iGPU `power_dpm_state` — see step 6 |

## Why this exists

Built end-to-end in one night. The 401 was misdiagnosed three times ("reset the client identity", "delete
`sunshine_state.json`", "you have two Sunshine instances") before a bare `openssl s_client` handshake with the same
client certificate succeeded — proving the certificate was fine and the failure was the client's certificate
*validation*, not the pairing state. Every entry in the table above is that kind of trap: the error message points
somewhere other than the cause.
