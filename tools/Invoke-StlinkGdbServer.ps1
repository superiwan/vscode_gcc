[CmdletBinding()]
param(
    [ValidateSet("Start", "Stop")]
    [string]$Action = "Start",
    [string]$GdbServerPath,
    [string]$ProgrammerPath,
    [int]$Port = 61234
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\STM32.Common.ps1"

function Stop-StlinkProcesses {
    $names = @("ST-LINK_gdbserver", "stlinkserver")
    $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in $names }
    if ($processes) {
        $processes | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
}

if ($Action -eq "Stop") {
    Stop-StlinkProcesses
    Write-Host "已停止 ST-LINK gdbserver。"
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($ProgrammerPath) -and (Test-Path -LiteralPath $ProgrammerPath -PathType Leaf)) {
    $ProgrammerPath = Split-Path -Parent (Resolve-Path -LiteralPath $ProgrammerPath).Path
}

$tools = Get-Stm32ToolPaths -ProgrammerPath $ProgrammerPath -StlinkGdbServerPath $GdbServerPath

if (-not $tools.StlinkGdbServer) {
    throw "找不到 ST-LINK_gdbserver。请先安装 ST-LINK_gdbserver，或在本地 .vscode/settings.json 里设置 stm32.stlinkGdbServerPath。"
}

if (-not $tools.CubeProgrammer) {
    throw "找不到 STM32CubeProgrammer。请先安装 STM32CubeProgrammer，或在本地 .vscode/settings.json 里设置 stm32.cubeProgrammerPath。"
}

$programmerBin = Split-Path -Parent $tools.CubeProgrammer

if (-not (Test-Path -LiteralPath $programmerBin)) {
    throw "找不到 STM32CubeProgrammer bin 目录：$programmerBin"
}

Stop-StlinkProcesses

$arguments = @(
    "-p", $Port,
    "-d",
    "-v",
    "-cp", $programmerBin
)

Start-Process -FilePath $tools.StlinkGdbServer -ArgumentList $arguments -WindowStyle Hidden
Start-Sleep -Seconds 2

$listener = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port }
if (-not $listener) {
    throw "ST-LINK gdbserver 没有成功启动。请先确认 ST-LINK 没被其他程序占用。"
}

Write-Host "ST-LINK gdbserver 已启动，端口：$Port"
