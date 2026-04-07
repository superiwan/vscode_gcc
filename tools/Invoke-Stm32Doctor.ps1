[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Get-Location).Path
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\STM32.Common.ps1"

$resolvedWorkspace = Resolve-WorkspacePath -Path $WorkspaceRoot
$tools = Get-Stm32ToolPaths

$rows = @(
    [pscustomobject]@{ Tool = "CMake"; Path = $tools.CMake; Ready = [bool]$tools.CMake }
    [pscustomobject]@{ Tool = "Ninja"; Path = $tools.Ninja; Ready = [bool]$tools.Ninja }
    [pscustomobject]@{ Tool = "arm-none-eabi-gcc"; Path = $tools.ArmGcc; Ready = [bool]$tools.ArmGcc }
    [pscustomobject]@{ Tool = "arm-none-eabi-gdb"; Path = $tools.ArmGdb; Ready = [bool]$tools.ArmGdb }
    [pscustomobject]@{ Tool = "STM32CubeMX"; Path = $tools.CubeMX; Ready = [bool]$tools.CubeMX }
    [pscustomobject]@{ Tool = "STM32CubeProgrammer"; Path = $tools.CubeProgrammer; Ready = [bool]$tools.CubeProgrammer }
    [pscustomobject]@{ Tool = "ST-LINK_gdbserver"; Path = $tools.StlinkGdbServer; Ready = [bool]$tools.StlinkGdbServer }
)

Write-Host "工作区: $resolvedWorkspace"
$rows | Format-Table -AutoSize

$missing = $rows | Where-Object { -not $_.Ready } | Select-Object -ExpandProperty Tool
if ($missing) {
    Write-Host ""
    Write-Host "缺少工具: $($missing -join ', ')"
    exit 1
}

Write-Host ""
Write-Host "环境已齐备。"
