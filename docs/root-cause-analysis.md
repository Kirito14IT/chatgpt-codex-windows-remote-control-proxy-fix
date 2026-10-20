# 根因分析实录：Codex 桌面端「无法更新远程控制状态」

> 本文是 [README](../README.md) 的技术细节版，保留全部原始日志与实测数据，便于他人复核与复现。

## 摘要

| 编号 | 根因 | 归属 | 状态 |
|---|---|---|---|
| **R1** | 桌面端原生进程 `codex.exe` 不继承系统代理 → 直连被 DNS 污染的伪造 IP → `os error 10060` | **本机环境**（网络需代理 + 客户端不认代理） | ✅ 已修复（注入 `HTTP_PROXY`） |
| **R2** | 桌面端 Electron 主进程的 `wss://codex-cloud-backend.chatgpt.com/` 通道**不读任何代理**、URL 硬编码无配置项 | **Codex 侧缺陷** | ❌ 未修复（已整理为上游 issue） |
| **R3** | `features.respect_system_proxy=true` 开启后远程控制 WS 反而 `errored` | **Codex 侧缺陷** | ❌ 未修复（已整理为上游 issue） |
| **R4** | 本机 mihomo TUN 反复失败（残留 Wintun 驱动 + 异常 Hyper-V 虚拟交换机适配器） | **本机环境** | ⚠️ 部分修复（与开关本身无关） |

---

## R1：主因（已修复）

### 症状链路

```
用户点击「允许连接」
  → 渲染进程发出 RPC: remoteControl/enable
  → codex.exe (Rust app-server) 处理
  → 需要建立 Noise 加密隧道 wss://chatgpt.com/backend-api/wham/remote/control/server
  → TCP 连接超时 (os error 10060)
  → RPC 返回错误
  → 界面弹「无法更新远程控制状态」
```

### 证据 1：报错原文

桌面端日志（`%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\...\codex-desktop-*.log`）：

```
2026-10-20T05:02:39.876Z info [electron-message-handler] remote_connections.connection_state_changed
  error={"code":"connection-failed","message":"{...
    \"message\":\"failed to connect to app-server remote control websocket\",
    \"websocket_url\":\"wss://chatgpt.com/backend-api/wham/remote/control/server\",
    \"installation_id\":\"d3bc1bc1-0420-4cfb-8a40-faf8a7bd074e\",
    \"server_name\":\"Kirco\",
    \"error\":\"failed to connect app-server remote control websocket
              `wss://chatgpt.com/backend-api/wham/remote/control/server`:
              IO error: 由于连接方在一段时间后没有正确答复或连接的主机没有反应，连接尝试失败。 (os error 10060)\",
    \"error_kind\":\"Other\",\"reconnect_attempt\":1,\"has_enrollment\":true,
    \"server_id\":\"Some(\\\"srv_e_6aab7e9027308326a78aa564411e1880\\\")\",
    \"environment_id\":\"Some(\\\"env_e_6aab7e9027208326bf868e350508e356\\\")\"}"}
```

要点：
* `os error 10060` = **WSAETIMEDOUT**（TCP 连接超时），不是 TLS 失败、不是 HTTP 403、不是认证失败；
* `has_enrollment: true` + 已存在 `server_id` / `environment_id` → **账号与设备注册都是好的**，纯网络问题；
* 从 17:02 持续重试到 18:40，`reconnect_attempt` 累计 **456** 次全部失败。

### 证据 2：socket 状态显示「HTTP 走代理、WS 直连」

```
# codex.exe 的全部外连
127.0.0.1        7897  Established     (x5)   ← 普通 API 请求，走本地代理
74.86.226.234    443  SynSent                   ← 远程控制 WS，直连伪造 IP，卡在 SYN
```

### 证据 3：DNS 投毒

```
Resolve-DnsName chatgpt.com   →  108.160.170.43
Resolve-DnsName chatgpt.com   →  31.13.95.48
Resolve-DnsName chatgpt.com   →  74.86.226.234
Resolve-DnsName chatgpt.com   →  199.59.149.232      ← 每次都不同
Resolve-DnsName www.microsoft.com → 23.209.214.100   ← 对照，正常
```

`Test-NetConnection chatgpt.com -Port 443` → `TcpTestSucceeded: False`（直连不通）。

### 证据 4：A/B 对照实验（决定性）

方法：直接运行桌面端同款二进制 `codex.exe remote-control --no-daemon`，只切换一个变量，观察日志中是否出现
`connected to app-server remote control websocket`。

| 组 | `HTTP_PROXY`/`HTTPS_PROXY` | 附加开关 | 结果 |
|---|---|---|---|
| A | 有 | — | **✅ Connected**（09:43:18） |
| E | 有 | — | **✅ CONNECTED**（复现） |
| B | 有 | `-c features.respect_system_proxy=true` | ❌ `Error: Remote control is enabled on Kirco but the connection is errored.` |
| C | 清空 | — | ❌ `os error 10060`（与桌面端完全一致） |
| D | 清空 | `-c features.network_proxy=true -c network.proxy_url="http://127.0.0.1:7897"` | ❌ `os error 10060` |

**结论**：连通与否**只取决于进程环境里有没有代理环境变量**。
`respect_system_proxy` 走的是 Windows 注册表里的系统代理路径，对这条 WS **不可用**；
`network.proxy_url` 属于沙箱网络代理（`features.network_proxy`），作用域是沙箱里的命令，不覆盖 app-server 自身传输层。

### 修复与复验

```powershell
setx HTTP_PROXY  "http://127.0.0.1:7897"
setx HTTPS_PROXY "http://127.0.0.1:7897"
setx NO_PROXY    "localhost,127.0.0.1,::1"
# 完全退出并重开 ChatGPT 桌面端
```

复验：

```
codex.exe 外连                →  127.0.0.1:7897 Established (x2)
直连伪造 IP 的 SYN_SENT       →  0 条
桌面端日志                    →  os error 10060 消失
                                Local Work executor connected to rendezvous
```

---

## R2 / R3：Codex 侧缺陷（未修复）

### R2：Electron 主进程的长连接通道不认任何代理

桌面端除了 app-server，还有一条**由 Electron 主进程发起**的 WebSocket：

```js
// app.asar 内硬编码
var uue = `wss://codex-cloud-backend.chatgpt.com/`;
function lb(e){ return { id: i.Ai, display_name: `Long-lived`, kind: `local`, websocket_url: uue } }
```

特征：
* URL **硬编码**，包内没有任何配置项可以覆盖；
* 使用 Node 的 `ws` 库（主进程），**既不读 Windows 系统代理（WinINET），也不读 `HTTP_PROXY`**；
* 实测 socket：`128.242.240.218:443 SynSent`（直连伪造 IP），日志报
  `WebSocket was closed before the connection was established`（1006，`failureReason=open_timeout`）。

对比：`app.asar` 里虽然出现过 `HTTP_PROXY`/`HTTPS_PROXY`/`CODEX_PROXY_CERT` 字符串，但它们属于
**传给沙箱命令的环境变量白名单**（`shell_environment_policy`），不是给主进程 WS 用的代理实现。

### Cloudflare 对该端点的 UA 敏感（影响 issue 复现）

```
$ curl -x http://127.0.0.1:7897 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: <random>' \
    -H 'Origin: https://chatgpt.com' \
    https://codex-cloud-backend.chatgpt.com/

无 User-Agent        → HTTP/1.1 403 Forbidden   (server: cloudflare)
User-Agent: node     → HTTP/1.1 403 Forbidden
User-Agent: codex-desktop/26.1013.4894.0 → HTTP/1.1 101 Switching Protocols
User-Agent: ChatGPT/26.1013.4894.0        → HTTP/1.1 101 Switching Protocols
```

也就是说：**只要让这条 WS 走上代理并带上可接受的 UA，它就能握手成功**。
在「系统代理 + 无 TUN」这一中国大陆普遍存在的网络形态下，这条通道必然失败。

### R3：`respect_system_proxy` 开启后反而失败

见 A/B 表 B 组：开启后 app-server 立刻以
`Error: Remote control is enabled on <name> but the connection is errored.` 退出，
日志里是 `failed to connect app-server remote control websocket`。
说明该特性在系统代理路径上的实现对 WS 传输层不可用（推测代理 URL/认证/协议协商处理有缺陷）。

---

## R4：本机 TUN 反复失败（与开关无关，但会连带影响其它原生程序）

mihomo 核心日志（`C:\ProgramData\clash-verge-service\users\<id>\logs\service_latest.log`）：

```
[2026-10-20 18:32:51] WARN  [TUN] default interface changed by monitor, => WLAN
[2026-10-20 18:33:06] WARN  Start Tun interface timeout: The device is not ready for use. [retrying 1/3]
[2026-10-20 18:33:21] WARN  Start Tun interface timeout: The device is not ready for use. [retrying 2/3]
[2026-10-20 18:33:36] WARN  Start Tun interface timeout: The device is not ready for use. [retrying 3/3]
[2026-10-20 18:33:36] ERROR Start TUN listening error: configure tun interface: The device is not ready for use.
```

排查发现：

1. 驱动包列表里有 **2021 年旧版 Clash for Windows 残留的 wintun**：
   ```
   Published Name: oem97.inf | Original Name: wintun.inf | Provider: WireGuard LLC
   Driver Version: 10/13/2021 0.14.0.0
   ```
   `wintun` 服务注册也指向它，适配器设备节点（`ROOT\WINTUN\0000`）长期处于 **Error / ProblemCode 56**。
2. **7 个 `Hyper-V 虚拟交换机扩展适配器`（`ROOT\VMS_VSMP\0000~0006`）全部 Error**，
   `DeviceSetupManager` 事件 121 报 `SWD\Wintun\{9E6FE1DA-...}` 安装驱动更新失败 `0x80072EFE`。
3. 清理旧驱动包 + 摘除异常 VMS_VSMP 设备后，mihomo 能重新注册 wintun 驱动
   （System 事件 7045：服务已安装，`wintun.sys` 时间戳更新），但适配器仍 `Not Present`，
   需一次干净启动才能让内核驱动就绪。

> 注意：整个 mihomo 核心是以 **LocalSystem**（`clash_verge_service` 服务）运行的，权限充足，
> 因此不是权限问题；核心日志里也没有任何 CodeIntegrity 签名拦截记录。

---

## 附：本机关键路径速查

```
# 桌面端 app 包（MSIX）
C:\Program Files\WindowsApps\OpenAI.Codex_26.1013.4894.0_x64__2p2nqsd0c76g0\
  app\resources\app.asar                     # 前端 bundle + i18n 文案
  app\ChatGPT.exe                             # Electron 主进程

# 桌面端日志
%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\

# codex 配置与登录
%USERPROFILE%\.codex\config.toml
%USERPROFILE%\.codex\auth.json

# 桌面端内嵌的原生二进制（被 app 复制到用户目录）
%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe

# mihomo 核心与配置（服务模式）
C:\ProgramData\clash-verge-service\cores\verge-mihomo.exe
C:\ProgramData\clash-verge-service\users\<id>\runtime\config.yaml
C:\ProgramData\clash-verge-service\users\<id>\logs\service_latest.log
```
