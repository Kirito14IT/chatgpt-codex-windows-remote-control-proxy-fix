# ChatGPT / Codex 桌面端「无法更新远程控制状态」完整排查与修复（Windows）

> 症状文案原文：**「无法更新远程控制状态」**、**「无法启用远程控制」**、**「无法启用远程控制。请重试」**
> 英文关键词：*ChatGPT desktop app "remote control" fails on Windows, "Could not enable remote control", Codex remote control not working, os error 10060, wss://codex-cloud-backend.chatgpt.com, HTTP_PROXY not honored, mihomo TUN "The device is not ready for use"*
> 上游 issue：<https://github.com/openai/codex/issues/55557>

本文记录一次**完整、可复现**的排障过程：从「ChatGPT 桌面端 → 设置 → 连接 → 控制此电脑 → 允许连接」点击后弹红框报错，
到最终定位到 **DNS 污染 + 代理未被原生进程继承** 双重原因，并给出经过验证的修复方案与可复用脚本。

所有结论均来自本机实测（日志、socket 状态、A/B 对照实验），不是推测。

---

## TL;DR（90 秒快速修复）

在中国大陆等对 `chatgpt.com` 存在 **DNS 污染 / IP 封锁**的网络环境下，ChatGPT/Codex 桌面端的原生进程
（`codex.exe`）**默认不继承 Windows 系统代理**，于是它直连被污染的伪造 IP，TCP 握手进入黑洞，
最终报 `os error 10060`（WSAETIMEDOUT）→ 界面弹「无法更新远程控制状态」。

**修复（管理员/普通用户均可，无需重启电脑）：**

```powershell
# 1) 注入代理环境变量（指向你正在用的本地代理，Clash Verge 默认 7897）
setx HTTP_PROXY  "http://127.0.0.1:7897"
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx NO_PROXY    "localhost,127.0.0.1,::1"

# 2) 完全退出 ChatGPT 桌面端（托盘图标右键退出，不只是关窗口），再重新打开
# 3) 设置 → 连接 → 控制此电脑 → 打开「允许连接」
```

> `NO_PROXY` 一定要加，否则本地 app-server socket / 本地 MCP 服务可能被误送进代理。
> 撤销：`setx HTTP_PROXY ""`（`HTTPS_PROXY`、`NO_PROXY` 同理）。

### 修复后的实测状态（本机验证）

```
设置 → 连接 → 控制此电脑 → 「允许连接」  = 已打开（蓝色）
弹出「在你的设备上批准以远程控制这台电脑」+ 二维码配对弹窗  = 设备已上线
```

但**还有一条通道没修好**（与开关本身无关，见 §6）：

```
codex.exe (app-server) 外连   →  127.0.0.1:7897  Established     ✅ 走代理
Electron 主进程 长连接(durable) →  199.16.158.190:443  SynSent     ❌ 仍直连伪造 IP
```

**含义**：开关能开、设备能上线，靠的是 app-server 那条隧道（已被代理环境变量修好）；
但桌面端**云端回连本机**的长连接通道仍不可用，**实际从手机发起远程会话时可能仍然连不上**。
想彻底验证，请在手机上扫码试着实际操作一下这台电脑。

---

## 一、症状速查表

| 你看到的现象 | 根因 | 修复 |
|---|---|---|
| 设置 → 连接 → 点「允许连接」→ 弹「**无法更新远程控制状态**」 | 原生 `codex.exe` 直连被 DNS 污染的 IP，`os error 10060` | 注入 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量并重启桌面端 |
| 弹「**无法启用远程控制**」 | 同上，或服务端认为该设备已在线 | 同上；仍失败则查看 app-server 日志中的 `remoteControl/enable` 返回 |
| 弹「**无法启用远程控制。请重试**」（手机端授权弹窗） | 同上 | 同上 |
| 日志里 `WebSocket was closed before the connection was established`（`hostId=durable`） | 桌面端 Electron 主进程的 WebSocket **既不读系统代理也不读 `HTTP_PROXY`**，URL 硬编码 | 目前**无配置可改**，见 §6 与 [上游 issue](docs/upstream-issue-draft.md) |
| Clash Verge 开着 TUN 但没生效，日志 `Start TUN listening error: configure tun interface: The device is not ready for use.` | Wintun 驱动 / Hyper-V 虚拟交换机子系统异常 | 见 §5（**与上面的开关无关**，是本机另一个独立问题） |
| 电脑上其他程序正常，只有 Codex 系产品挂 | 同上：只有不认系统代理的原生进程会挂 | 注入代理环境变量 |

---

## 二、环境前提（我的实测环境）

| 组件 | 版本 / 状态 |
|---|---|
| 操作系统 | Windows 11 (CoreCountrySpecific) 10.0.26200 x64 |
| ChatGPT 桌面端 | MSIX 包 `OpenAI.Codex_26.1013.4894.0_x64__2p2nqsd0c76g0`（应用名显示为 ChatGPT，内含 Codex） |
| 内置 app-server | `codex 0.163.0-alpha.10.2`（Windows x86_64） |
| 代理客户端 | Clash Verge Rev（内核 `verge-mihomo`，服务模式 `clash_verge_service`，mixed-port 7897） |
| 网络 | 中国大陆，运营商 DNS 对 `chatgpt.com` 返回随机伪造 IP（GFW 污染） |

日志位置（排查时全靠它）：

```
# 桌面端主日志
%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\YYYY\MM\DD\codex-desktop-*.log

# mihomo 核心日志（服务模式下，在 ProgramData，需要管理员权限读取）
C:\ProgramData\clash-verge-service\users\<user-id>\logs\service_latest.log
```

---

## 三、根因分析：完整证据链

### 3.1 界面报错的真实来源

桌面端报错文案来自 app 包内的 i18no 词条（`app.asar`）：

```
"settings.remoteConnections.localHost.remoteControlUpdateError": "无法更新远程控制状态"
"settings.remoteConnections.remoteControlServerAlreadyOnline": "无法启用远程控制"
"codexMobile.setupDialog.allowHost.error": "无法启用远程控制。请重试"
```

点击「允许连接」时，渲染进程会向 app-server 发出 `remoteControl/enable` RPC：

```
[AppServerConnection] response_routed method=remoteControl/enable durationMs=14 errorCode=null
```

### 3.2 它必须连到哪里

`codex.exe`（Rust 写的 app-server）需要建立一条 **Noise 加密的 WebSocket 隧道**：

```
wss://chatgpt.com/backend-api/wham/remote/control/server
```

失败时的原文（本机日志逐字）：

```
failed to connect app-server remote control websocket
  `wss://chatgpt.com/backend-api/wham/remote/control/server`:
  IO error: 由于连接方在一段时间后没有正确答复或连接的主机没有反应，连接尝试失败。 (os error 10060)
```

`os error 10060` = **WSAETIMEDOUT，TCP 连接超时**——不是 TLS 失败、不是 403、不是认证拒绝。
本机从 17:02 到 18:40 共重试 **456 次全部失败**，错误文案一字不变。

### 3.3 为什么连不上：DNS 污染 + 直连

`codex.exe` 的 socket 状态（`Get-NetTCPConnection`）：

```
# 普通 API 请求 —— 走代理，正常
127.0.0.1 : 7897   Established   (x5)

# 远程控制 WebSocket —— 直连公网 IP，卡在 SYN_SENT
74.86.226.234 : 443   SynSent
```

同一个进程，HTTP 走代理、WS 直连。而 `chatgpt.com` 的 DNS 结果是**每次都不同的伪造 IP**：

```
第一次  Resolve-DnsName chatgpt.com -> 108.160.170.43
第二次  Resolve-DnsName chatgpt.com -> 31.13.95.48
第三次  Resolve-DnsName chatgpt.com -> 74.86.226.234
第四次  Resolve-DnsName chatgpt.com -> 199.59.149.232
对照    Resolve-DnsName www.microsoft.com -> 23.209.214.100   (正常)
```

**直连这些伪造 IP 必然进黑洞**，于是 `os error 10060`。

### 3.4 那它为什么不用代理？——A/B 对照实验

关键实验：桌面端的 `codex.exe` **用户级/系统级环境变量里根本没有 `HTTP_PROXY`**
（`HKCU:\Environment` 与系统级 env 都没有），所以它只能直连。

我用 `codex remote-control --no-daemon` 做了 5 组对照实验，每组只改一个变量，直接看日志里
`connected to app-server remote control websocket` 这行是否出现：

| 组 | 代理环境变量 | 附加开关 | 结果 |
|---|---|---|---|
| A | ✅ 有 | 无 | **✅ Connected** |
| E | ✅ 有 | 无 | **✅ CONNECTED**（复现 A） |
| B | ✅ 有 | `-c features.respect_system_proxy=true` | ❌ `Remote control is enabled on Kirco but the connection is errored.` |
| C | ❌ 清空 | 无 | ❌ **os error 10060**（与桌面端报错完全一致） |
| D | ❌ 清空 | `-c features.network_proxy=true -c network.proxy_url=...` | ❌ os error 10060 |

结论：

1. **能不能连通，只取决于进程环境里有没有 `HTTP_PROXY`/`HTTPS_PROXY`**；
2. `features.respect_system_proxy`（读 Windows 注册表里的系统代理）**开启后反而失败**；
3. `network.proxy_url` / `network.socks_url` 是**沙箱**网络代理用的，对 app-server 自身传输层无效。

### 3.5 顺带查清的两件事

**(a) 代理出口本身完全正常。** 经代理访问目标端点，Cloudflare 正常返回：

```
HTTP/1.1 200 Connection established
HTTP/1.1 400 Bad Request        ← 服务器收到了请求（裸握手没带 Noise 认证）
server: cloudflare
x-oai-request-id: ...
```

**(b) 但 Cloudflare 会按 User-Agent 拦截 WebSocket 升级**（这条对写 issue 很重要）：

| User-Agent | `wss://codex-cloud-backend.chatgpt.com/` 升级结果 |
|---|---|
| 无 UA | 403 ❌ |
| `node` | 403 ❌ |
| `codex-desktop/26.1013.4894.0` | **101 Switching Protocols ✅** |
| `ChatGPT/26.1013.4894.0` | **101 ✅** |
| 浏览器 UA | **101 ✅** |

---

## 四、修复方案

### 方案 A（推荐，30 秒）：注入代理环境变量

```powershell
setx HTTP_PROXY  "http://127.0.0.1:7897"
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx NO_PROXY    "localhost,127.0.0.1,::1"
```

然后**完全退出** ChatGPT 桌面端（托盘退出）并重开——子进程必须重新继承环境变量，旧进程不会自动获得。

**修复后的实测证据：**

```
codex.exe 外连   →  127.0.0.1:7897  Established   (x2~x5)
直连伪造IP的 SYN_SENT  →  0 条
桌面端日志      →  os error 10060 消失
                 Local Work executor connected to rendezvous   ← 隧道建立成功
```

### 方案 B：修好 Clash 的 TUN（透明代理）

只有当**其他不认系统代理的原生程序**也连不上 OpenAI 服务时才有必要（方案 A 已经能解决 Codex 本身）。
TUN 还能顺带解决 DNS 污染问题（fake-ip 劫持）。

本机 TUN 起不来的确切原因（从 mihomo 核心日志读到）：

```
Start Tun interface timeout: The device is not ready for use. [retrying 1/3]
Start TUN listening error: configure tun interface: The device is not ready for use.
```

排查发现系统里存在**两个互相冲突的 Wintun 驱动来源**：

```
Published Name: oem97.inf | Original Name: wintun.inf | Provider: WireGuard LLC
Driver Version: 10/13/2021 0.14.0.0        ← 旧版 Clash for Windows 留下的残留
```

以及 7 个处于 **Error** 状态的 `Hyper-V 虚拟交换机扩展适配器`（`ROOT\VMS_VSMP\0000~0006`），
它们会阻塞 Wintun 创建网卡。处理顺序：

```powershell
# 需要管理员
sc stop wintun
sc delete wintun
pnputil /delete-driver oem97.inf /uninstall /force

# 摘掉坏掉的 Hyper-V 伪设备（Hyper-V/WSL 需要时会自动重建）
Get-PnpDevice | ? InstanceId -match 'VMS_VSMP' | % { pnputil /remove-device $_.InstanceId /subtree }

# 重启 HNS 与 Clash Verge Service
net stop hns ; net start hns
net stop clash_verge_service ; net start clash_verge_service
```

> ⚠️ 我在实测中**先卸载了 Wintun 设备再重启**，导致驱动需要在一次启动周期里重新干净加载。
> 如果你直接从头做（先删驱动包 + 删坏设备，再重启电脑），成功率更高。

### 方案 C：改 hosts / 只换 DNS —— **实测无效，不要浪费时间**

```
# hosts 写 chatgpt.com 真实 IP → 仍然失败
curl --resolve chatgpt.com:443:172.64.155.209 https://chatgpt.com/
  * Recv failure: Connection was reset
  * schannel: failed to receive handshake, SSL/TLS connection failed
```

真实 IP 本身也走不通（TLS 握手被 RST），所以**只修 DNS 不能解决问题**，必须走代理。

---

## 五、诊断脚本

`scripts/` 目录提供四个 PowerShell 脚本，**全部只读或可回滚**：

| 脚本 | 作用 | 权限 |
|---|---|---|
| `scripts/diagnose.ps1` | 一键体检：代理环境变量、DNS 污染、TUN 状态、wintun 驱动、桌面端日志里的关键报错 | 普通用户 |
| `scripts/verify.ps1` | 修复后验证：TUN 三指标 + 桌面端进程是否还在直连伪造 IP | 普通用户 |
| `scripts/fix-proxy-env.ps1` | 注入 / 撤销 `HTTP_PROXY` 等环境变量 | 普通用户 |
| `scripts/fix-wintun-tun.ps1` | 清理残留 wintun 驱动 + 坏掉的 Hyper-V 适配器，重启 HNS 与 Clash 服务 | **管理员** |

```powershell
# 体检
powershell -ExecutionPolicy Bypass -File scripts\diagnose.ps1

# 修复（方案 A）
powershell -ExecutionPolicy Bypass -File scripts\fix-proxy-env.ps1 -Action apply

# 修复（方案 B，管理员）
powershell -ExecutionPolicy Bypass -File scripts\fix-wintun-tun.ps1

# 验证
powershell -ExecutionPolicy Bypass -File scripts\verify.ps1
```

---

## 六、已知未解决项（Codex 侧缺陷，已整理为上游 issue）

即使方案 A 生效，桌面端还有**第二条通道**不可用：

```
wss://codex-cloud-backend.chatgpt.com/     ← app 包内硬编码的 "Long-lived" 主机
```

* 桌面端 Electron 主进程用 Node 的 `ws` 客户端连接它，**既不读 Windows 系统代理，也不读 `HTTP_PROXY`**；
* URL 硬编码，**没有任何配置项**可以改；
* 结果：它直连 → 命中伪造 IP → `SynSent` → `WebSocket was closed before the connection was established`（1006）。

在「系统代理 + 无 TUN」这一在中国大陆**非常普遍**的环境下，Codex 的云端长连接必然不可用。

**已提交上游 issue：<https://github.com/openai/codex/issues/55557>**
（`bug(windows-os): desktop app "Long-lived" host WebSocket ignores system proxy and HTTP_PROXY, hardcoded URL`）

详细的复现步骤、日志证据、已排除项和建议修复方向见
[`docs/upstream-issue-draft.md`](docs/upstream-issue-draft.md)。

---

## 七、搜索关键词索引

如果你是在搜索这个问题，可以试试这些组合（本仓库已针对它们优化）：

**中文**
`无法更新远程控制状态` · `无法启用远程控制` · `ChatGPT 桌面端 远程控制 失败` ·
`Codex 远程控制 连不上` · `codex 远程控制 os error 10060` ·
`wss://chatgpt.com/backend-api/wham/remote/control/server` ·
`wss://codex-cloud-backend.chatgpt.com` · `Codex 不走代理` · `Codex 桌面端 代理` ·
`Clash Verge TUN 起不来` · `Start TUN listening error configure tun interface` ·
`The device is not ready for use wintun` · `wintun 驱动 卸载` ·
`DNS 污染 chatgpt.com 伪造 IP` · `HTTP_PROXY codex`

**English**
`ChatGPT desktop app remote control error Windows` · `Codex remote control could not enable` ·
`codex os error 10060 WSAETIMEDOUT` · `codex app-server remote control websocket failed` ·
`codex HTTP_PROXY environment variable not honored` · `codex respect_system_proxy` ·
`codex-cloud-backend.chatgpt.com websocket 403` · `mihomo TUN device is not ready for use` ·
`wintun driver stale clash for windows` · `Hyper-V virtual switch extension adapter error wintun`

---

## 八、免责声明

本文是个人排障笔记，**与 OpenAI 无任何关联**。涉及的产品名仅用于描述问题现象。
脚本只做只读诊断或可回滚的系统配置修改，请在理解其作用后再执行；管理员脚本会修改驱动与设备注册，
**请先备份重要工作**。不同网络环境下的表现可能不同，请以本机实测为准。

## License

MIT
