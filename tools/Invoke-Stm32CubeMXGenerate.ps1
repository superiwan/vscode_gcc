[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$ProjectRoot,
    [string]$IocPath,
    [string]$ProjectName,
    [string]$CubeMxPath,
    [int]$GenerationTimeoutSeconds = 120,
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
$cubeMxExe = $tools.CubeMX

$resolvedIoc = Get-SingleIocFile -WorkspaceRoot $resolvedWorkspace -IocPath $IocPath

if ($OpenGuiOnly) {
    Start-Process -FilePath $cubeMxExe -ArgumentList @($resolvedIoc)
    Write-Host "已打开 CubeMX: $resolvedIoc"
    exit 0
}

$javaExe = Join-Path (Split-Path -Parent $cubeMxExe) "jre\bin\java.exe"
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
    Push-Location (Split-Path -Parent $cubeMxExe)
    Write-Host ""
    Write-Host "$javaExe -jar $cubeMxExe -q $scriptPath"

    $process = [System.Diagnostics.Process]::Start($javaExe, ('-jar "{0}" -q "{1}"' -f $cubeMxExe, $scriptPath))

    if (-not $process.WaitForExit($GenerationTimeoutSeconds * 1000)) {
        $rootCMakeLists = Join-Path $resolvedProjectRoot "CMakeLists.txt"
        if (Test-Path -LiteralPath $rootCMakeLists) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Write-Host "CubeMX 已生成 CMakeLists.txt，但进程未自动退出，已终止残留进程。"
            return
        }

        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "CubeMX 生成超时，且未找到根 CMakeLists.txt：$resolvedProjectRoot"
    }

    if ($process.ExitCode -ne 0) {
        throw "命令执行失败：$javaExe"
    }
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
}
