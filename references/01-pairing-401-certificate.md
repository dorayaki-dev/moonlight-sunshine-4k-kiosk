# 01 · 配对报 401 `Server certificate mismatch` 的完整证据链

> 这是整个项目里最耗时的坑。**报错信息、官方文档、issue 区的答案，三方全都指向错误的方向。**

## 症状

电视上点主机图标 → kiosk 显示一个 4 位 PIN → 在 Sunshine Web UI 里输入该 PIN → 发送 → **电视弹窗**：

```
GeForce Experience returned error: Server certificate mismatch (Error 401)
```

也可能出现 `Another pairing request is waiting for PIN entry (Error 409)` —— 那是上一个请求还挂着，属于**次生现象**。

## 三个流行的"已知修法" —— 全都无效 ✗

| 尝试 | 结果 | 为什么无效 |
|---|---|---|
| 重置客户端身份（删配置里的 `uniqueid` / `certificate` / `key`）| 仍 401 | 客户端证书本来就是好的 |
| 删除主机端 `sunshine_state.json` 后重启 | 仍 401 | 服务端配对记录也不是原因 |
| 重装 / 升级 Sunshine | 仍 401 | 版本不是原因 |
| 排查"是不是有两个 Sunshine 实例" | 有时是真凶 | **但只影响"电视上两个图标"，不产生本 401** |

## 证据链：三步定位到真正原因

### 第 1 步 —— 打开客户端的真实日志（它默认不落盘）

kiosk 常由 `xinit` 拉起，输出进了 tty，`journalctl` 里什么都没有。在启动 App 前加一行：

```bash
export QT_LOGGING_RULES="qt.network.ssl=true"
exec 2>>/tmp/moonlight.log
"$MOONLIGHT" &
```

重试一次配对，日志里会看到决定性的三行：

```
Executing request: "https://<HOST>:47984/pair?...&phrase=pairchallenge"
Qt Warning: Neither X509_STORE, nor SSL contains error list, handshake failure
Qt Warning: "pair" request failed with error: QNetworkReply::SslHandshakeFailedError
```

> 注意失败发生在**最后一个 HTTPS 请求**上。前面 `getservercert` / `clientchallenge` /
> `serverchallengeresp` / `clientpairingsecret` 全部成功 —— 也就是说 **PIN 输得没问题**，
> 挂在的是握手的 TLS 层。

### 第 2 步 —— 用同一张客户端证书做裸握手，证明证书是好的

从客户端配置里导出它自己的证书与私钥，然后**绕过 Moonlight** 直接握手：

```bash
# 从客户端配置导出（值是 QSettings 的 @ByteArray(...) 形式，\n 需要还原成换行）
python3 - <<'PY'
import re
t = open("<CONFIG_DIR>/Moonlight.conf", encoding="utf-8", errors="replace").read()
for key, out in (("certificate", "/tmp/c.crt"), ("key", "/tmp/c.key")):
    m = re.search(key + r'="@ByteArray\((.*?)\)"', t, re.S)
    open(out, "w").write(m.group(1).replace(chr(92) + "n", "\n"))
PY

echo | openssl s_client -connect <HOST>:47984 -cert /tmp/c.crt -key /tmp/c.key 2>&1 \
  | grep -E "Protocol|Cipher|Verify|alert"
```

结果：**握手成功** ✅ —— `New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384`。

> 这里有个关键区别，也是这个坑最迷惑人的地方：`openssl s_client` **默认不会因为"证书不可信"而中止**，
> 它只打印 `verify error:num=18:self-signed certificate` 然后照常完成握手；
> 而 **Moonlight 的 Qt/OpenSSL 会直接中止**。所以"openssl 能连、Moonlight 不能"→ 问题一定在**证书校验**，
> 不在网络、不在 PIN、不在配对状态。

### 第 3 步 —— 结论

Sunshine 使用**自签名证书**。Moonlight 在配对最后的 TLS 校验阶段验证它 → 验证失败 →
中断握手 → 把这种失败暴露为 `Server certificate mismatch (Error 401)`
（这条错误字符串来自 Moonlight 源码里 `SslHandshakeFailedError` 的分支，和真实原因只勉强沾边）。

## 修法

把主机证书安装进**客户端**的信任库：

```bash
echo | openssl s_client -connect <HOST>:47984 -showcerts 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/sunshine.crt

sudo cp /tmp/sunshine.crt /usr/local/share/ca-certificates/sunshine-host.crt
sudo update-ca-certificates

# 严格校验现在必须通过
echo | openssl s_client -connect <HOST>:47984 -verify_return_error 2>&1 | grep "Verify return code"
# 期望：Verify return code: 0 (ok)
```

AppImage 形式的 Moonlight 自带 OpenSSL，未必读取系统默认的信任路径，所以在服务单元里再钉一遍：

```ini
# /etc/systemd/system/moonlight.service.d/ssl.conf
[Service]
Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
Environment=SSL_CERT_DIR=/etc/ssl/certs
```

重启客户端 → 点主机 → 电视显示 PIN → 在 `https://<HOST>:47990` 输入 → 发送 → **这次会通过** ✅

成功标志：客户端配置里出现主机记录且带 `srvcert`（不再是空的 `@ByteArray()`），
并且用它的 UID 查询主机返回 `PairStatus 1`：

```bash
curl -s "http://<HOST>:47989/serverinfo?uniqueid=<CLIENT_UID>&uuid=$(cat /proc/sys/kernel/random/uuid|tr -d -)" \
  | tr '<' '\n' | grep PairStatus
```

## 顺带排除：真的有两个 Sunshine 实例吗？

这与本 401 无关，但会制造"电视上两个同名主机图标"的混乱。判据：

```bash
# 电视端（客户端日志）发现了几个 mDNS 主机
grep -c "Discovered mDNS host" /tmp/moonlight.log

# 主机端：跑着的 Sunshine 进程数
tasklist /FI "IMAGENAME eq sunshine.exe"      # Windows
```

若确实有两个（常见于升级后旧版没卸干净），只保留一个再继续。
