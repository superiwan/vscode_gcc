[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$BuildDir,
    [string]$ProgrammerPath,
    [string]$TargetFile,
    [string]$FlashAddress = "0x08000000",
    [switch]$EraseOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\STM32.Common.ps1"

$resolvedWorkspace = Resolve-WorkspacePath -Path $WorkspaceRoot
$resolvedBuild = Resolve-OptionalPath -Path $BuildDir -BasePath $resolvedWorkspace
if (-not $resolvedBuild) {
    $resolvedBuild = Join-Path $resolvedWorkspace "build\Debug"
}

$resolvedTarget = Resolve-OptionalPath -Path $TargetFile -BasePath $resolvedWorkspace
$tools = Get-Stm32ToolPaths -ProgrammerPath $ProgrammerPath

if (-not $tools.CubeProgrammer) {
    throw "没有找到 STM32CubeProgrammer。请先安装 STM32CubeProgrammer。"
}

if ($EraseOnly) {
    Invoke-Native -Command $tools.CubeProgrammer -Arguments @(
        "-c", "port=SWD",
        "-e", "all"
    )
    exit 0
}

if (-not $resolvedTarget) {
    $resolvedTarget = Get-BuildArtifact -BuildDir $resolvedBuild
}

$extension = [System.IO.Path]::GetExtension($resolvedTarget).ToLowerInvariant()
if ($extension -eq ".bin") {
    Invoke-Native -Command $tools.CubeProgrammer -Arguments @(
        "-c", "port=SWD",
        "-w", $resolvedTarget, $FlashAddress,
        "-v",
        "-rst"
    )
    exit 0
}

Invoke-Native -Command $tools.CubeProgrammer -Arguments @(
    "-c", "port=SWD",
    "-d", $resolvedTarget,
    "-v",
    "-rst"
)
