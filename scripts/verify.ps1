<#
.SYNOPSIS
  验证 ChatGPT / Codex 远程控制修复是否生效（只读）。

.DESCRIPTION
  验证四件事：
    1. codex.exe 的外连是否全部指向本地代理（而不是直连伪造 IP）
    2. 是否还有进程在直连被污染的 IP（SYN_SENT）
    3. TUN 三指标是否达标（Mihomo 网卡 / 198.18 路由 / fake-ip 解析）
    4. 桌面端日志里最近一次远程控制是否成功

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File verify.ps1
#>

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn($t)  { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Bad($t)   { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t)  { Write-Host "  [INFO] $t" -ForegroundColor Gray }

Write-Host "修复验证  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

Section "1. 环境变量"
$u = Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue
foreach ($k in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
    if ($u.$k) { Ok "$k = $($u.$k)" } else { Bad "$k 未设置（桌面端子进程不会走代理）" }
}

Section "2. 桌面端原生进程外连"
$ap = Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'app-server' -and $_.CommandLine -notmatch 'vscode' } | Select-Object -First 1
if ($ap) {
    Info "app-server codex.exe PID=$($ap.ProcessId) 启动于 $($ap.CreationDate)"
    $conns = Get-NetTCPConnection -OwningProcess $ap.ProcessId -ErrorAction SilentlyContinue | Where-Object { $_.RemotePort -ne 0 }
    $proxy = @($conns | Where-Object { $_.RemoteAddress -in '127.0.0.1','::1' })
    $direct = @($conns | Where-Object { $_.RemoteAddress -notin '127.0.0.1','::1' -and $_.RemoteAddress -ne '0.0.0.0' })
    if ($proxy.Count -gt 0) { Ok "有 $($proxy.Count) 条连接经本地代理" } else { Warn "没有经代理的连接" }
    if ($direct.Count -gt 0) {
        Bad "仍有 $($direct.Count) 条直连公网 IP 的连接（可能是伪造 IP）"
        $direct | Select-Object -First 5 | ForEach-Object { Info ("    " + $_.RemoteAddress + ':' + $_.RemotePort + '  ' + $_.State) }
    } else { Ok "没有直连公网 IP 的连接" }
} else { Warn "未找到桌面端的 codex.exe app-server 进程（应用可能没在运行）" }

Section "3. TUN 三指标"
$tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Mihomo' }
if ($tun -and $tun.Status -eq 'Up') { Ok "Mihomo TUN 网卡已建立" }
elseif ($tun) { Warn "Mihomo 网卡存在但状态为 $($tun.Status)" }
else { Bad "没有 Mihomo TUN 网卡" }

$route = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -like '198.18.*' }
if ($route) { Ok "fake-ip 路由存在" } else { Bad "没有 198.18.0.0/16 路由" }

$ip = (Resolve-DnsName chatgpt.com -Type A -ErrorAction SilentlyContinue | Where-Object IPAddress | Select-Object -First 1).IPAddress
if ($ip -like '198.18.*') { Ok "chatgpt.com 已解析为 fake-ip：$ip" }
else { Warn "chatgpt.com 解析为 $ip（不是 fake-ip，DNS 仍可能被污染）" }

Section "4. 桌面端日志中的最近状态"
$logRoot = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs'
$log = Get-ChildItem $logRoot -Recurse -File -Filter 'codex-desktop-*.log' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Where-Object { $_.Length -gt 2000 } | Select-Object -First 1
if ($log) {
    Info "日志：$($log.Name)"
    $lines = Get-Content $log.FullName -Encoding UTF8 -Tail 8000 -ErrorAction SilentlyContinue
    $okConn = $lines | Where-Object { $_ -match 'connected to rendezvous|connected to app-server remote control websocket' } | Select-Object -Last 1
    $failConn = $lines | Where-Object { $_ -match 'os error 10060|rendezvous unavailable' } | Select-Object -Last 1
    if ($okConn) {
        $t = ($okConn -replace "`e\[[0-9;]*m",'') -replace '\s+',' '
        Ok "最近一次隧道连接成功：" + $t.Substring(0,[Math]::Min(120,$t.Length))
    } else { Bad "日志里还没有隧道连接成功的记录" }
    if ($failConn) {
        $t = ($failConn -replace "`e\[[0-9;]*m",'') -replace '\s+',' '
        Warn "最近一次失败：" + $t.Substring(0,[Math]::Min(150,$t.Length))
    }
    $durable = $lines | Where-Object { $_ -match 'hostId=durable' -and $_ -match 'error' } | Select-Object -Last 1
    if ($durable) { Warn "Electron 长连接(durable)通道仍失败——该通道不认任何代理，只能靠 TUN 解决" }
    else { Ok "durable 通道没有错误记录" }
} else { Warn "没找到有内容的桌面端日志" }

Write-Host ""
Write-Host "三项全绿 = 修复完成；仍报错时把 diagnose.ps1 的输出贴到 issue 里。" -ForegroundColor White
Write-Host ""
