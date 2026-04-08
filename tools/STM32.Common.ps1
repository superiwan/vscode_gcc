[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

function Resolve-WorkspacePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "工作区路径不能为空。"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-OptionalPath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Find-ToolInRoots {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,
        [string[]]$Roots
    )

    foreach ($root in ($Roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        $match = Get-ChildItem -LiteralPath $root -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName

        if ($match) {
            return $match
        }
    }

    return $null
}

function Resolve-ToolPath {
    param(
        [string]$ExplicitPath,
        [string]$CommandName,
        [string]$FileName,
        [string[]]$Roots,
        [string[]]$CandidatePaths
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolvedExplicit = Resolve-OptionalPath -Path $ExplicitPath
        if (Test-Path -LiteralPath $resolvedExplicit) {
            return $resolvedExplicit
        }

        throw "找不到指定的工具路径：$ExplicitPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    foreach ($candidate in ($CandidatePaths | Where-Object { $_ })) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    if ($FileName) {
        $found = Find-ToolInRoots -FileName $FileName -Roots $Roots
        if ($found) {
            return $found
        }
    }

    return $null
}

function Get-Stm32ToolPaths {
    param(
        [string]$CubeMxPath,
        [string]$ProgrammerPath,
        [string]$GdbPath,
        [string]$StlinkGdbServerPath
    )

    $stRoots = @(
        "C:\ST",
        "C:\Program Files\STMicroelectronics",
        "C:\Program Files (x86)\STMicroelectronics",
        "C:\Program Files (x86)\Arm GNU Toolchain arm-none-eabi",
        "$env:LOCALAPPDATA\stm32cube\bundles"
    )

    $paths = [ordered]@{
        CMake = Resolve-ToolPath -CommandName "cmake" -FileName "cmake.exe" -Roots @("C:\Program Files\CMake") -CandidatePaths @(
            "C:\Program Files\CMake\bin\cmake.exe"
        )
        Ninja = Resolve-ToolPath -CommandName "ninja" -FileName "ninja.exe" -Roots @("C:\ninja-win", "C:\Program Files") -CandidatePaths @(
            "C:\ninja-win\ninja.exe"
        )
        ArmGcc = Resolve-ToolPath -CommandName "arm-none-eabi-gcc" -FileName "arm-none-eabi-gcc.exe" -Roots $stRoots
        ArmGdb = Resolve-ToolPath -ExplicitPath $GdbPath -CommandName "arm-none-eabi-gdb" -FileName "arm-none-eabi-gdb.exe" -Roots $stRoots
        CubeMX = Resolve-ToolPath -ExplicitPath $CubeMxPath -CommandName "STM32CubeMX" -FileName "STM32CubeMX.exe" -Roots @(
            "C:\Program Files\STMicroelectronics\STM32Cube",
            "C:\Program Files (x86)\STMicroelectronics\STM32Cube"
        ) -CandidatePaths @(
            "C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeMX\STM32CubeMX.exe",
            "C:\Program Files (x86)\STMicroelectronics\STM32Cube\STM32CubeMX\STM32CubeMX.exe"
        )
        CubeProgrammer = Resolve-ToolPath -ExplicitPath $ProgrammerPath -CommandName "STM32_Programmer_CLI" -FileName "STM32_Programmer_CLI.exe" -Roots $stRoots -CandidatePaths @(
            "C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe",
            "C:\Program Files (x86)\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe",
            "$env:LOCALAPPDATA\stm32cube\bundles\programmer\2.22.0+st.1\bin\STM32_Programmer_CLI.exe"
        )
        StlinkGdbServer = Resolve-ToolPath -ExplicitPath $StlinkGdbServerPath -CommandName "ST-LINK_gdbserver" -FileName "ST-LINK_gdbserver.exe" -Roots $stRoots -CandidatePaths @(
            "$env:LOCALAPPDATA\stm32cube\bundles\stlink-gdbserver\7.13.0+st.3\bin\ST-LINK_gdbserver.exe"
        )
    }

    return [pscustomobject]$paths
}

function Get-SingleIocFile {
    param(
        [string]$WorkspaceRoot,
        [string]$IocPath
    )

    if (-not [string]::IsNullOrWhiteSpace($IocPath)) {
        $resolved = Resolve-OptionalPath -Path $IocPath -BasePath $WorkspaceRoot
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "找不到 .ioc 文件：$IocPath"
        }

        return $resolved
    }

    $iocFiles = Get-ChildItem -LiteralPath $WorkspaceRoot -Filter *.ioc -File -Recurse -ErrorAction SilentlyContinue
    if ($iocFiles.Count -eq 1) {
        return $iocFiles[0].FullName
    }

    if ($iocFiles.Count -gt 1) {
        throw "检测到多个 .ioc 文件。请先运行 Initialize-Stm32Workspace.ps1，或在本地 .vscode/settings.json 里设置 stm32.iocFile。"
    }

    throw "工作区里没有找到 .ioc 文件。"
}

function Get-BuildArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir
    )

    if (-not (Test-Path -LiteralPath $BuildDir)) {
        throw "构建目录不存在：$BuildDir"
    }

    $artifacts = Get-ChildItem -LiteralPath $BuildDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".elf", ".hex", ".bin") } |
        Sort-Object LastWriteTime -Descending

    if (-not $artifacts) {
        throw "构建目录里没有找到可下载文件：$BuildDir"
    }

    return $artifacts[0].FullName
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "$Command $($Arguments -join ' ')"
    & $Command @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "命令执行失败：$Command"
    }
}
