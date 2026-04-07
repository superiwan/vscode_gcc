[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$ProjectRoot,
    [string]$IocPath,
    [string]$ProjectName,
    [string]$CubeMxPath,
    [switch]$OpenGuiOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\STM32.Common.ps1"

$resolvedWorkspace = Resolve-WorkspacePath -Path $WorkspaceRoot
$resolvedProjectRoot = Resolve-OptionalPath -Path $ProjectRoot -BasePath $resolvedWorkspace
if (-not $resolvedProjectRoot) {
    $resolvedProjectRoot = $resolvedWorkspace
}

$tools = Get-Stm32ToolPaths -CubeMxPath $CubeMxPath
if (-not $tools.CubeMX) {
    throw "没有找到 STM32CubeMX。请先安装 STM32CubeMX。"
}

$resolvedIoc = Get-SingleIocFile -WorkspaceRoot $resolvedWorkspace -IocPath $IocPath

if ($OpenGuiOnly) {
    Start-Process -FilePath $tools.CubeMX -ArgumentList @($resolvedIoc)
    Write-Host "已打开 CubeMX: $resolvedIoc"
    exit 0
}

$javaExe = Join-Path (Split-Path -Parent $tools.CubeMX) "jre\bin\java.exe"
if (-not (Test-Path -LiteralPath $javaExe)) {
    throw "STM32CubeMX 自带的 Java 运行时不存在：$javaExe"
}

$scriptPath = Join-Path $env:TEMP ("stm32cubemx-" + [guid]::NewGuid().ToString("N") + ".txt")

$scriptLines = @(
    ('config load "{0}"' -f $resolvedIoc),
    'project toolchain CMake',
    ('project path "{0}"' -f $resolvedProjectRoot)
)

if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
    $scriptLines += ('project name "{0}"' -f $ProjectName)
}

$scriptLines += @(
    'project generate',
    'exit'
)

[System.IO.File]::WriteAllLines($scriptPath, $scriptLines)

try {
    Push-Location (Split-Path -Parent $tools.CubeMX)
    Invoke-Native -Command $javaExe -Arguments @(
        "-jar", $tools.CubeMX,
        "-q", $scriptPath
    )
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
}
