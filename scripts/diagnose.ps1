<#
.SYNOPSIS
  ChatGPT / Codex 桌面端「无法更新远程控制状态」一键体检（只读，不修改任何东西）。

.DESCRIPTION
  检查五件事：
    1. 进程环境里有没有 HTTP_PROXY / HTTPS_PROXY（codex.exe 能否走代理）
    2. chatgpt.com 的 DNS 是否被污染（返回伪造 IP）
    3. Clash Verge / mihomo 的 TUN 是否真正建立
    4. Wintun 驱动与 Hyper-V 虚拟交换机适配器是否异常
    5. 桌面端日志里最近一次远程控制失败的报错类型

  全部为只读操作。管理员权限不是必需的。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File diagnose.ps1
#>

$ErrorActionPreference = 'Continue'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn($t)  { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Bad($t)   { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t)  { Write-Host "  [INFO] $t" -ForegroundColor Gray }

Write-Host "ChatGPT / Codex 远程控制体检  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

# ---------------------------------------------------------------- 1. 代理环境变量
Section "1. 代理环境变量（codex.exe 是否能走代理）"
$envProxy = @{ HTTP_PROXY=$env:HTTP_PROXY; HTTPS_PROXY=$env:HTTPS_PROXY; NO_PROXY=$env:NO_PROXY }
$userEnv  = Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue
$sysEnv   = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue

foreach ($k in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
    $u = $userEnv.$k; $s = $sysEnv.$k; $p = $envProxy[$k]
    if ($u)      { Ok  "$k 用户级已设置 = $u（桌面端子进程会继承）" }
    elseif ($p)  { Warn "$k 仅当前会话有值 = $p（新启动的桌面端拿不到）" }
    elseif ($s)  { Ok  "$k 系统级已设置 = $s" }
    else         { Bad "$k 未设置 —— 桌面端原生进程会直连被污染的 IP" }
}

$ik = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($ik -and $ik.ProxyEnable -eq 1) { Info "Windows 系统代理已开启：$($ik.ProxyServer)"; Info "注意：只认系统代理的程序（如 Electron 渲染进程）能用它，原生 Rust 进程通常不能。" }
else { Warn "Windows 系统代理未开启" }

# ---------------------------------------------------------------- 2. DNS 污染
Section "2. DNS 污染检测（chatgpt.com 是否返回伪造 IP）"
$real = @()
try {
    $doh = curl.exe -s -x "http://127.0.0.1:7897" --max-time 15 -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=chatgpt.com&type=A" 2>$null | ConvertFrom-Json
    $real = @($doh.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
} catch { }
$poison = @()
1..3 | ForEach-Object {
    $ip = (Resolve-DnsName chatgpt.com -Type A -ErrorAction SilentlyContinue | Where-Object IPAddress | Select-Object -First 1).IPAddress
    if ($ip) { $poison += $ip }
}
if ($poison.Count -gt 0) {
    Info "系统 DNS 返回：$($poison -join ', ')"
    if ($real.Count -gt 0) {
        Info "真实 IP（经代理 DoH）：$($real -join ', ')"
        if (($poison | Where-Object { $real -notcontains $_ }).Count -gt 0) { Bad "存在与真实 IP 不符的结果 —— DNS 被污染" }
        else { Ok "系统 DNS 与真实 IP 一致 —— 未见污染" }
    } else { Warn "无法用 DoH 取真实 IP（代理可能不通），无法自动对比" }
    if ($poison.Count -gt 1 -and (($poison | Select-Object -Unique).Count -gt 1)) { Bad "多次解析返回不同 IP —— 典型的 DNS 投毒特征" }
} else { Warn "无法解析 chatgpt.com" }

# ---------------------------------------------------------------- 3. TUN 状态
Section "3. Clash Verge / mihomo TUN 状态"
$mihomo = Get-CimInstance Win32_Process -Filter "Name='verge-mihomo.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $mihomo) { Warn "未找到 verge-mihomo 进程（Clash Verge 未运行？）" }
else { Ok "mihomo 核心运行中 PID=$($mihomo.ProcessId)" }

$tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Mihomo' }
if ($tun) { Ok "TUN 网卡存在：$($tun.Name) => $($tun.Status)" } else { Bad "没有 Mihomo TUN 网卡（透明代理未生效）" }

$route = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -like '198.18.*' }
if ($route) { Ok "fake-ip 路由存在：$($route[0].DestinationPrefix)" } else { Bad "没有 198.18.0.0/16 路由（fake-ip 未生效，DNS 仍会被污染）" }

$listen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 7897,7898,7899 }
if ($listen) { Ok "代理端口在监听：$(($listen.LocalPort | Sort-Object -Unique) -join ', ')" } else { Bad "没有代理端口在监听" }

# ---------------------------------------------------------------- 4. 驱动与虚拟网卡
Section "4. Wintun 驱动 / Hyper-V 虚拟交换机适配器"
$svc = sc.exe query wintun 2>&1 | Out-String
if ($svc -match 'STATE\s*:\s*(\d+)') {
    $state = $matches[1]
    if ($state -eq '1') { Info "wintun 驱动已注册且未运行（按需启动，属正常）" }
} else { Warn "wintun 驱动服务未注册（mihomo TUN 可能不可用）" }

$pkg = pnputil.exe /enum-drivers 2>&1 | Out-String
if ($pkg -match '(?s)Published Name:\s*(oem\d+\.inf).*?Original Name:\s*wintun\.inf.*?Driver Version:\s*([\d/]+)\s*([\d.]+)') {
    $ver = "$($matches[2]) $($matches[3])"
    if ($ver -match '0\.14\.0\.0') { Warn "Wintun 驱动包 $ver —— 旧版 Clash for Windows 残留，需清理（见 fix-wintun-tun.ps1）" }
    else { Ok "Wintun 驱动包版本 $ver" }
} else { Info "驱动包列表中未发现 wintun" }

$vs = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VMS_VSMP' })
$bad = @($vs | Where-Object { $_.Status -ne 'OK' })
if ($bad.Count -gt 0) {
    Bad "$($bad.Count)/$($vs.Count) 个 Hyper-V 虚拟交换机扩展适配器处于异常状态（会阻塞 Wintun 建卡）"
    $bad | Select-Object -First 8 | ForEach-Object { Info ("    " + $_.InstanceId + " => " + $_.Status) }
} elseif ($vs.Count -gt 0) { Ok "Hyper-V 虚拟交换机适配器状态正常" }
else { Ok "没有 Hyper-V 虚拟交换机扩展适配器（不构成冲突）" }

# ---------------------------------------------------------------- 5. 桌面端日志
Section "5. ChatGPT 桌面端最近一次远程控制报错"
$logRoot = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs'
if (-not (Test-Path $logRoot)) { $logRoot = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.ChatGPT_8wekyb3d8bbwe\LocalCache\Local\ChatGPT\Logs' }
if (Test-Path $logRoot) {
    $log = Get-ChildItem $logRoot -Recurse -File -Filter 'codex-desktop-*.log' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Where-Object { $_.Length -gt 2000 } | Select-Object -First 1
    if ($log) {
        Info "日志：$($log.Name)  ($($log.Length) bytes, $($log.LastWriteTime))"
        $lines = Get-Content $log.FullName -Encoding UTF8 -Tail 6000 -ErrorAction SilentlyContinue
        $err = $lines | Where-Object { $_ -match 'os error 10060|rendezvous unavailable|failed to connect to app-server remote control websocket' } | Select-Object -Last 1
        if ($err) {
            $t = ($err -replace "`e\[[0-9;]*m",'') -replace '\s+',' '
            if ($t -match 'os error 10060') { Bad "远程控制隧道连接超时（os error 10060）—— 原生进程没有走代理" }
            else { Warn "最近一次远程控制异常：" + $t.Substring(0,[Math]::Min(220,$t.Length)) }
        } else { Ok "最近日志中没有远程控制隧道失败记录" }

        $durable = $lines | Where-Object { $_ -match 'hostId=durable' -and $_ -match 'error' } | Select-Object -Last 1
        if ($durable) {
            $t = ($durable -replace "`e\[[0-9;]*m",'') -replace '\s+',' '
            Warn "Electron 长连接通道(durable)仍失败：" + $t.Substring(0,[Math]::Min(200,$t.Length))
            Info "该通道硬编码 wss://codex-cloud-backend.chatgpt.com/ 且不读任何代理，只能靠 TUN 解决"
        }
    } else { Warn "没找到有内容的桌面端日志" }
} else { Warn "未找到桌面端日志目录" }

Section "结论与建议"
Write-Host "  若第 1 节显示 HTTP_PROXY 未设置 -> 执行 fix-proxy-env.ps1 -Action apply，然后完全退出并重开桌面端" -ForegroundColor White
Write-Host "  若第 3 节 TUN 未生效 且 第 4 节有异常设备 -> 以管理员执行 fix-wintun-tun.ps1（建议随后重启电脑）" -ForegroundColor White
Write-Host "  执行完用 verify.ps1 复核" -ForegroundColor White
Write-Host ""
