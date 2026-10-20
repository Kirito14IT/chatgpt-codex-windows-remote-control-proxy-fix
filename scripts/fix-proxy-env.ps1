<#
.SYNOPSIS
  修复 ChatGPT / Codex 桌面端「无法更新远程控制状态」：注入 / 撤销代理环境变量。

.DESCRIPTION
  原理：
    桌面端内嵌的原生进程 codex.exe（Rust）默认**不读 Windows 系统代理**，
    只有当进程环境里存在 HTTP_PROXY / HTTPS_PROXY 时才会走代理。
    在 chatgpt.com 被 DNS 污染的网络环境下，不走代理就会直连伪造 IP，
    TCP 握手进黑洞 -> os error 10060 -> 界面弹「无法更新远程控制状态」。

  本脚本只写入当前用户的环境变量（HKCU\Environment），可随时撤销。

.PARAMETER Action
  apply = 设置（默认）；clear = 撤销；show = 只显示当前值

.PARAMETER ProxyUrl
  代理地址，默认 http://127.0.0.1:7897（Clash Verge 默认 mixed-port）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File fix-proxy-env.ps1 -Action apply
  powershell -ExecutionPolicy Bypass -File fix-proxy-env.ps1 -Action clear
#>

[CmdletBinding()]
param(
    [ValidateSet('apply','clear','show')] [string]$Action = 'apply',
    [string]$ProxyUrl = 'http://127.0.0.1:7897',
    [string]$NoProxy = 'localhost,127.0.0.1,::1'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Show-Current {
    Write-Host "当前用户级环境变量（HKCU:\Environment）：" -ForegroundColor Cyan
    $u = Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue
    foreach ($k in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
        $v = $u.$k
        if ($v) { Write-Host ("  {0,-12} = {1}" -f $k, $v) -ForegroundColor Green }
        else    { Write-Host ("  {0,-12} = (未设置)" -f $k) -ForegroundColor DarkGray }
    }
}

switch ($Action) {
    'show' { Show-Current; break }

    'apply' {
        # 先确认代理端口真的在监听，别写进去一个不存在的代理
        $port = ([uri]$ProxyUrl).Port
        $ok = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if (-not $ok) {
            Write-Warning "本机 $ProxyUrl 没有在监听（端口 $port）。请先启动代理客户端，否则设置后反而会连不上。"
        } else {
            Write-Host "代理端口 $port 正在监听 ✓" -ForegroundColor Green
        }

        [Environment]::SetEnvironmentVariable('HTTP_PROXY',  $ProxyUrl, 'User')
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $ProxyUrl, 'User')
        [Environment]::SetEnvironmentVariable('NO_PROXY',    $NoProxy,  'User')
        Write-Host "已写入用户级环境变量：HTTP_PROXY / HTTPS_PROXY = $ProxyUrl ，NO_PROXY = $NoProxy" -ForegroundColor Green
        Show-Current
        Write-Host ""
        Write-Host "下一步：完全退出 ChatGPT 桌面端（托盘图标右键退出），再重新打开。" -ForegroundColor Yellow
        Write-Host "旧进程不会自动获得新环境变量，必须重启应用；改完后到 设置 → 连接 → 控制此电脑 打开「允许连接」。" -ForegroundColor Yellow
    }

    'clear' {
        foreach ($k in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
            [Environment]::SetEnvironmentVariable($k, $null, 'User')
        }
        Write-Host "已清除用户级 HTTP_PROXY / HTTPS_PROXY / NO_PROXY" -ForegroundColor Green
        Show-Current
        Write-Host "记得重启 ChatGPT 桌面端使其生效。" -ForegroundColor Yellow
    }
}
