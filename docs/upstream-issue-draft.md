# 上游 Issue 草稿：桌面端长连接通道不遵循任何代理

> 目标仓库：<https://github.com/openai/codex>
> 建议标签：`bug` `windows-os`
> 状态：**待提交**（本文是草稿，尚未在 GitHub 上创建 issue）

---

## 标题（建议）

```
bug(windows-os): desktop app "Long-lived" host WebSocket ignores system proxy and HTTP_PROXY, hardcoded URL
```

中文对照：桌面端「Long-lived」主机 WebSocket 既不遵循系统代理也不遵循 `HTTP_PROXY`，且 URL 硬编码无法配置

---

## 正文

### 环境

| 项 | 值 |
|---|---|
| 应用 | ChatGPT 桌面端（Windows，MSIX 包 `OpenAI.Codex_26.1013.4894.0_x64__2p2nqsd0c76g0`） |
| 内置 app-server | `codex 0.163.0-alpha.10.2`（windows-x86_64） |
| OS | Windows 11 10.0.26200 x64 |
| 代理 | Clash Verge Rev（mihomo 内核），Windows 系统代理开启（`ProxyEnable=1`，`127.0.0.1:7897`），TUN 未启用 |
| 网络 | 存在 DNS 污染：`chatgpt.com` 被解析到随机伪造 IP |

### 问题描述

桌面端在 `remoteControl/enable` 之后会建立一条名为 `hostId=durable`（显示名 `Long-lived`）的 WebSocket：

```js
// app.asar（硬编码，无任何配置项可覆盖）
var uue = `wss://codex-cloud-backend.chatgpt.com/`;
function lb(e){ return { id: i.Ai, display_name: `Long-lived`, kind: `local`, websocket_url: uue } }
```

这条连接由 Electron **主进程**用 Node 的 `ws` 库发起（不是 Chromium 网络栈），结果是：

1. **不读 Windows 系统代理**（WinINET / `ProxyEnable` + `ProxyServer`）——尽管 app-server 内的 HTTP 客户端会读；
2. **不读 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量**——尽管同一进程树里的 `codex.exe` 会读（见下）；
3. URL 硬编码，**没有任何设置项**可以替换。

在「系统代理 + 未开 TUN」这一在中国大陆非常普遍的网络形态下，该通道**必然失败**。

### 复现步骤

1. Windows 开启系统代理（指向本地 HTTP 代理），**不**开启 TUN；
2. 确保该环境对 `chatgpt.com` 存在 DNS 污染（或任何需要代理才能访问的网络）；
3. 启动 ChatGPT 桌面端，打开 设置 → 连接 → 控制此电脑，打开「允许连接」；
4. 观察桌面端日志
   （`%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\`）：

```
[AppServerConnection] app_server_connection.websocket_error connectionId=58 errorCode=unknown
  hostKind=durable message="WebSocket was closed before the connection was established" transport=websocket
[AppServerConnection] app_server_connection.closed code=1006 connectionId=58 failureReason=open_timeout
[AppServerConnection] app_server_connection.reconnect_scheduled baseDelayMs=20000 reconnectAttempt=57
```

5. 同时用 `Get-NetTCPConnection` 观察主进程 socket，可见**直连公网 IP 的 `SynSent`**（而非连本地代理）：

```
RemoteAddress    RemotePort  State
127.0.0.1        7897        Established      ← Chromium 侧流量走代理
199.16.158.190   443         SynSent          ← 长连接直连，命中 DNS 污染的伪造 IP
```

### 对照实验：app-server 侧其实**会**读代理环境变量

同一台机器、同一份订阅，只改一个变量，直接看 `codex.exe remote-control --no-daemon` 的日志：

| 组 | `HTTP_PROXY`/`HTTPS_PROXY` | 开关 | 结果 |
|---|---|---|---|
| A | 有 | — | ✅ `connected to app-server remote control websocket` |
| E | 有 | — | ✅ 复现 A |
| B | 有 | `-c features.respect_system_proxy=true` | ❌ `Error: Remote control is enabled on <name> but the connection is errored.` |
| C | 清空 | — | ❌ `os error 10060`（WSAETIMEDOUT） |
| D | 清空 | `-c features.network_proxy=true -c network.proxy_url=...` | ❌ `os error 10060` |

**结论**：`codex.exe`（Rust app-server）**认 `HTTP_PROXY`**，而桌面端主进程里那条 WS **不认**——
同一个应用、同一个进程树，代理行为不一致。

另外两点值得注意：

* `features.respect_system_proxy=true`（读 Windows 注册表系统代理）**开启后反而失败**，
  app-server 立刻以 `connection is errored` 退出，看起来该特性在 WS 传输层上的系统代理解析路径有问题；
* `network.proxy_url` / `network.socks_url`（`features.network_proxy`）只作用于**沙箱内命令**的网络策略，
  不作用于 app-server 自身的长连接。

### 该端点本身是可用的（说明不是服务端问题）

经本地代理做 WS 升级握手（`curl`）：

```
User-Agent: 无                              → HTTP/1.1 403 Forbidden
User-Agent: node                            → HTTP/1.1 403 Forbidden
User-Agent: codex-desktop/26.1013.4894.0    → HTTP/1.1 101 Switching Protocols
User-Agent: ChatGPT/26.1013.4894.0          → HTTP/1.1 101 Switching Protocols
```

只要走上代理并带上可接受的 UA，握手即成功 → **服务端与网络出口都正常**。

### 期望行为（建议）

1. 桌面端主进程发起的 WebSocket **遵循 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`**（与 app-server 保持一致）；
2. 至少**遵循 Windows 系统代理**（WinINET），使「只开系统代理」的常见配置可用；
3. 提供一个**可配置的端点覆盖**（如 `CODEX_CLOUD_BACKEND_URL` / settings 项），便于自建网关与企业环境；
4. 修复 `features.respect_system_proxy`，使其在 WS 传输层可用（当前开启即失败）。

### 影响面

在中国大陆、以及任何「必须走代理但只开系统代理、未开 TUN」的环境下，
桌面端的云端长连接不可用，**从手机端发起的远程控制会话可能无法真正建立**——
尽管「允许连接」开关能打开、设备能显示为在线。

### 补充：把代理环境变量补上后，开关恢复正常，但这条通道依旧不通

这正好把问题**隔离**到了本 issue 描述的这条通道上：

```
# 设置用户级代理环境变量并重启桌面端之后
设置 → 连接 → 控制此电脑 → 「允许连接」  =>  已打开，二维码配对弹窗正常弹出 ✅
桌面端日志                                =>  os error 10060 消失，
                                             Local Work executor connected to rendezvous ✅

# 但长连接通道依然是直连伪造 IP
codex.exe (app-server) 外连              =>  127.0.0.1:7897  Established  ✅
Electron 主进程 长连接(durable) 外连      =>  199.16.158.190:443  SynSent  ❌
```

也就是说：**「允许连接」开关本身由 app-server 那条隧道支撑（已通），
而云端回连本机、由 Electron 主进程发起的那条通道完全没有被代理接管（仍不通）。**
换句话说，打开开关 ≠ 远程会话真的能建立。

### 环境补充信息（供复现）

```
桌面端日志目录：
%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\<YYYY>\<MM>\<DD>\codex-desktop-*.log

Codex CLI 二进制（与桌面端同一份，路径由桌面端复制到用户目录）：
%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe
```

---

## 备选：更短的问题描述（如果 maintainer 希望精简）

```
bug(windows-os): desktop app main-process WebSocket ignores proxies

The desktop app opens a hardcoded WebSocket to wss://codex-cloud-backend.chatgpt.com/
("Long-lived" host) from the Electron main process using the `ws` package. It reads
neither the Windows system proxy nor HTTP_PROXY/HTTPS_PROXY, so on any network that
requires a proxy (e.g. behind a corporate/regional proxy) it connects directly and
fails with `WebSocket was closed before the connection was established` (1006,
failureReason=open_timeout).

The Rust app-server in the same process tree DOES honor HTTP_PROXY (verified by A/B
test with `codex remote-control --no-daemon`), so the behavior is inconsistent.

Asks:
 1. honor HTTP_PROXY/HTTPS_PROXY (and Windows system proxy) for this connection;
 2. allow overriding the endpoint;
 3. `features.respect_system_proxy=true` currently makes the app-server WS fail with
    "connection is errored" — please check that path.
```
