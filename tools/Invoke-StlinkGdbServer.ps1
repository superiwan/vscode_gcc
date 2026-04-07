[CmdletBinding()]
param(
    [ValidateSet("Start", "Stop")]
    [string]$Action = "Start",
    [string]$GdbServerPath = "C:\Users\prohibit\AppData\Local\stm32cube\bundles\stlink-gdbserver\7.13.0+st.3\bin\ST-LINK_gdbserver.exe",
    [string]$ProgrammerPath = "C:\Users\prohibit\AppData\Local\stm32cube\bundles\programmer\2.22.0+st.1\bin",
    [int]$Port = 61234
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

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

if (-not (Test-Path -LiteralPath $GdbServerPath)) {
    throw "找不到 ST-LINK_gdbserver：$GdbServerPath"
}

if (-not (Test-Path -LiteralPath $ProgrammerPath)) {
    throw "找不到 STM32CubeProgrammer bin 目录：$ProgrammerPath"
}

Stop-StlinkProcesses

$arguments = @(
    "-p", $Port,
    "-d",
    "-v",
    "-cp", $ProgrammerPath
)

Start-Process -FilePath $GdbServerPath -ArgumentList $arguments -WindowStyle Hidden
Start-Sleep -Seconds 2

$listener = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port }
if (-not $listener) {
    throw "ST-LINK gdbserver 没有成功启动。请先确认 ST-LINK 没被其他程序占用。"
}

Write-Host "ST-LINK gdbserver 已启动，端口：$Port"
