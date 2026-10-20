<#
.SYNOPSIS
  修复 ChatGPT / Codex 桌面端「无法更新远程控制状态」：清理残留 Wintun 驱动与异常 Hyper-V 虚拟交换机适配器。

.DESCRIPTION
  背景：
    Codex 桌面端的 Electron 主进程有一条**硬编码**的 WebSocket 通道
    （wss://codex-cloud-backend.chatgpt.com/），它既不读系统代理也不读 HTTP_PROXY，
    只能依靠 mihomo 的 **TUN 透明代理** 才能工作。

    而 TUN 起不来的典型原因是：
      1) 系统里残留着别的软件（旧版 Clash for Windows / 加速器）安装的旧版 Wintun 驱动包；
      2) 多个 `Hyper-V 虚拟交换机扩展适配器`（ROOT\VMS_VSMP\*）处于 Error 状态，阻塞 Wintun 建卡。

  本脚本做四件事：
    1) 停止并删除 wintun 驱动服务注册
    2) 删除旧的 wintun 驱动包（oem*.inf）
    3) 摘掉处于异常状态的 ROOT\VMS_VSMP\* 伪设备
    4) 重启 HNS 与 Clash Verge Service，让 mihomo 用自带的新版 wintun 重建 TUN 网卡

  ⚠️ 需要管理员权限。脚本会修改驱动与设备注册，建议**先保存工作**。
  ⚠️ 执行后建议**重启一次电脑**，让新装的内核驱动在一次干净的启动周期里加载。

.EXAMPLE
  # 在管理员 PowerShell 中
  powershell -ExecutionPolicy Bypass -File fix-wintun-tun.ps1
#>

[CmdletBinding()]
param(
    [switch]$SkipServiceRestart
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限。请用「以管理员身份运行」的 PowerShell 执行本脚本。" -ForegroundColor Red
    Write-Host "（或：右键脚本 → 使用 PowerShell 运行）" -ForegroundColor Yellow
    exit 1
}

function Step($n, $t) { Write-Host ""; Write-Host "[$n] $t" -ForegroundColor Cyan }

Step 1 "停止并删除 wintun 驱动服务注册"
Write-Host (sc.exe stop wintun 2>&1 | Out-String).Trim()
Write-Host (sc.exe delete wintun 2>&1 | Out-String).Trim()

Step 2 "删除已安装的 wintun 驱动包"
$pkgs = pnputil.exe /enum-drivers 2>&1 | Out-String
$names = [regex]::Matches($pkgs, 'Published Name:\s*(oem\d+\.inf)(?s:.*?)Original Name:\s*wintun\.inf') | ForEach-Object { $_.Groups[1].Value }
if ($names) {
    foreach ($n in $names) {
        Write-Host "  删除驱动包 $n"
        Write-Host (pnputil.exe /delete-driver $n /uninstall /force 2>&1 | Out-String).Trim()
    }
} else { Write-Host "  未发现 wintun 驱动包，跳过" }

Step 3 "摘掉处于异常状态的 Hyper-V 虚拟交换机扩展适配器"
$bad = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VMS_VSMP' -and $_.Status -ne 'OK' })
if ($bad.Count -gt 0) {
    foreach ($d in $bad) {
        Write-Host "  移除 $($d.InstanceId)  (状态 $($d.Status))"
        Write-Host (pnputil.exe /remove-device $d.InstanceId /subtree 2>&1 | Out-String).Trim()
    }
} else { Write-Host "  没有异常状态的 VMS_VSMP 设备，跳过" }

Step 4 "重启 HNS 与 Clash Verge Service"
Write-Host (net.exe stop hns 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 3
Write-Host (net.exe start hns 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 4

if (-not $SkipServiceRestart) {
    Write-Host (net.exe stop clash_verge_service 2>&1 | Out-String).Trim()
    Start-Sleep -Seconds 4
    Write-Host (net.exe start clash_verge_service 2>&1 | Out-String).Trim()
}

Start-Sleep -Seconds 20
Step 5 "当前状态"
$tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Mihomo' }
if ($tun) { Write-Host "  TUN 网卡：$($tun.Name) => $($tun.Status)" -ForegroundColor Green }
else { Write-Host "  还没有 Mihomo TUN 网卡（通常需要重启电脑让新装的内核驱动干净加载）" -ForegroundColor Yellow }
$route = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -like '198.18.*' }
if ($route) { Write-Host "  fake-ip 路由：$($route[0].DestinationPrefix)" -ForegroundColor Green }
else { Write-Host "  还没有 198.18.0.0/16 路由" -ForegroundColor Yellow }

Write-Host ""
Write-Host "建议：现在重启一次电脑，然后启动 Clash Verge（确认 TUN 模式已开启）与 ChatGPT 桌面端。" -ForegroundColor Yellow
Write-Host "重启后运行 verify.ps1 复核。" -ForegroundColor Yellow
