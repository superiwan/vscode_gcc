[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\STM32.Common.ps1"

$TemplateRoot = Split-Path -Parent $PSScriptRoot
$SkipNames = @(".git", ".vscode", "tools", "build", ".stm32-init-backup", ".omx")
$ManagedStateFileName = ".stm32-workspace-state.json"
$ManagedBackupKeepCount = 3
$CurrentManagedEntries = @(
    ".vscode",
    "tools",
    ".clangd",
    ".gitignore",
    ".ignore",
    ".stm32-workspace-state.json"
)

function Add-UniqueItem {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Test-SkippedPath {
    param(
        [string]$Root,
        [string]$Path
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($Path)

    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $relativePath = $fullPath.Substring($fullRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return $false
    }

    $segments = $relativePath -split '[\\/]'
    foreach ($segment in $segments) {
        if ($segment -in $SkipNames) {
            return $true
        }
    }

    return $false
}

function Get-WorkspaceFiles {
    param(
        [string]$Root,
        [string]$Filter
    )

    Get-ChildItem -LiteralPath $Root -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-SkippedPath -Root $Root -Path $_.FullName) }
}

function Get-UniqueFile {
    param(
        [string]$Root,
        [string]$Filter
    )

    $files = @(Get-WorkspaceFiles -Root $Root -Filter $Filter)
    if ($files.Count -eq 1) {
        return $files[0].FullName
    }

    return $null
}

function Get-IocValue {
    param(
        [string]$IocPath,
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $IocPath)) {
        return $null
    }

    $pattern = '^{0}=(.*)$' -f [regex]::Escape($Key)
    $match = Select-String -LiteralPath $IocPath -Pattern $pattern
    if ($match) {
        return $match.Matches[0].Groups[1].Value.Trim()
    }

    return $null
}

function ConvertTo-SafeProjectName {
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "Stm32Project"
    }

    $safeName = $Name -replace '[^A-Za-z0-9._-]', '_'
    $safeName = $safeName -replace '_+', '_'
    $safeName = $safeName.Trim(' ', '.', '_', '-')

    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return "Stm32Project"
    }

    return $safeName
}

function Test-ConcreteDevice {
    param(
        [string]$Device
    )

    if ([string]::IsNullOrWhiteSpace($Device)) {
        return $false
    }

    return $Device -notmatch 'xx$'
}

function Get-CMakeProjectName {
    param(
        [string]$CMakeListsPath
    )

    if (-not (Test-Path -LiteralPath $CMakeListsPath)) {
        return $null
    }

    $content = Get-Content -LiteralPath $CMakeListsPath -Raw
    $setMatch = [regex]::Match($content, '(?im)^\s*set\s*\(\s*CMAKE_PROJECT_NAME\s+([^\s\)]+)')
    if ($setMatch.Success) {
        return $setMatch.Groups[1].Value.Trim('"')
    }

    $projectMatch = [regex]::Match($content, '(?im)^\s*project\s*\(\s*([^\s\)]+)')
    if ($projectMatch.Success) {
        return $projectMatch.Groups[1].Value.Trim('"')
    }

    return $null
}

function Set-CMakeProjectName {
    param(
        [string]$CMakeListsPath,
        [string]$ProjectName
    )

    if (-not (Test-Path -LiteralPath $CMakeListsPath)) {
        return $false
    }

    $content = Get-Content -LiteralPath $CMakeListsPath -Raw
    $updated = $content

    $updated = [regex]::Replace(
        $updated,
        '(?im)^(\s*set\s*\(\s*CMAKE_PROJECT_NAME\s+)([^\s\)]+)(\s*\))',
        {
            param($match)
            '{0}{1}{2}' -f $match.Groups[1].Value, $ProjectName, $match.Groups[3].Value
        },
        1
    )

    $updated = [regex]::Replace(
        $updated,
        '(?im)^(\s*project\s*\(\s*)([^\s\)]+)',
        {
            param($match)
            '{0}{1}' -f $match.Groups[1].Value, $ProjectName
        },
        1
    )

    if ($updated -eq $content) {
        return $false
    }

    Set-Content -LiteralPath $CMakeListsPath -Value $updated -Encoding utf8
    return $true
}

function Set-IocProjectMetadata {
    param(
        [string]$IocPath,
        [string]$ProjectName,
        [string]$ProjectFileName
    )

    $content = Get-Content -LiteralPath $IocPath -Raw

    if ($content -match '(?m)^ProjectManager\.ProjectName=') {
        $content = [regex]::Replace($content, '(?m)^ProjectManager\.ProjectName=.*$', "ProjectManager.ProjectName=$ProjectName")
    } else {
        $content = $content.TrimEnd("`r", "`n") + "`r`nProjectManager.ProjectName=$ProjectName`r`n"
    }

    if ($content -match '(?m)^ProjectManager\.ProjectFileName=') {
        $content = [regex]::Replace($content, '(?m)^ProjectManager\.ProjectFileName=.*$', "ProjectManager.ProjectFileName=$ProjectFileName")
    } else {
        $content = $content.TrimEnd("`r", "`n") + "`r`nProjectManager.ProjectFileName=$ProjectFileName`r`n"
    }

    Set-Content -LiteralPath $IocPath -Value $content -Encoding utf8
}

function Get-LinkerDeviceCandidate {
    param(
        [string]$Root
    )

    foreach ($file in (Get-WorkspaceFiles -Root $Root -Filter *.ld | Sort-Object FullName)) {
        $match = [regex]::Match($file.BaseName, '^(STM32[A-Z0-9]+)_(FLASH|RAM)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Groups[1].Value.ToUpperInvariant()
        }
    }

    return $null
}

function Get-StartupDeviceCandidate {
    param(
        [string]$Root
    )

    foreach ($file in (Get-WorkspaceFiles -Root $Root -Filter startup_*.s | Sort-Object FullName)) {
        $match = [regex]::Match($file.Name, '^startup_(stm32[a-z0-9]+)\.s$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Groups[1].Value.ToUpperInvariant().Replace("XX", "xx")
        }
    }

    return $null
}

function Get-FamilyCandidate {
    param(
        [string]$Root
    )

    $paths = @(
        (Join-Path $Root "Drivers"),
        (Join-Path $Root "Drivers\CMSIS\Device\ST")
    )

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $path -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^STM32[A-Z0-9]+xx$' } |
            Select-Object -First 1

        if ($match) {
            return $match.Name
        }
    }

    return $null
}

function Backup-Path {
    param(
        [string]$SourcePath,
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    $destination = Join-Path $BackupRoot (Split-Path -Leaf $SourcePath)
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Recurse -Force
}

function Backup-File {
    param(
        [string]$FilePath,
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return
    }

    $filesRoot = Join-Path $BackupRoot "files"
    if (-not (Test-Path -LiteralPath $filesRoot)) {
        New-Item -ItemType Directory -Path $filesRoot | Out-Null
    }

    Copy-Item -LiteralPath $FilePath -Destination (Join-Path $filesRoot (Split-Path -Leaf $FilePath)) -Force
}

function Get-ManagedStatePath {
    param(
        [string]$ProjectPath
    )

    return (Join-Path $ProjectPath $ManagedStateFileName)
}

function Read-ManagedState {
    param(
        [string]$ProjectPath
    )

    $statePath = Get-ManagedStatePath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Remove-ManagedEntry {
    param(
        [string]$ProjectPath,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $false
    }

    $targetPath = Join-Path $ProjectPath $RelativePath
    if (-not (Test-Path -LiteralPath $targetPath)) {
        return $false
    }

    $resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
    $resolvedTargetPath = [System.IO.Path]::GetFullPath($targetPath)
    if (-not $resolvedTargetPath.StartsWith($resolvedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝删除超出工程目录的路径：$RelativePath"
    }

    Remove-Item -LiteralPath $targetPath -Recurse -Force
    return $true
}

function Remove-StaleManagedEntries {
    param(
        [string]$ProjectPath,
        [string[]]$CurrentEntries
    )

    $state = Read-ManagedState -ProjectPath $ProjectPath
    if (-not $state -or -not $state.managedEntries) {
        return @()
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($state.managedEntries)) {
        if ($entry -notin $CurrentEntries) {
            if (Remove-ManagedEntry -ProjectPath $ProjectPath -RelativePath $entry) {
                $removed.Add($entry) | Out-Null
            }
        }
    }

    return @($removed)
}

function Remove-ManagedEntries {
    param(
        [string]$ProjectPath,
        [string[]]$Entries
    )

    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        if (Remove-ManagedEntry -ProjectPath $ProjectPath -RelativePath $entry) {
            $removed.Add($entry) | Out-Null
        }
    }

    return @($removed)
}

function Prune-BackupDirectories {
    param(
        [string]$ProjectPath,
        [int]$KeepLatest = 3
    )

    $backupContainer = Join-Path $ProjectPath ".stm32-init-backup"
    if (-not (Test-Path -LiteralPath $backupContainer)) {
        return @()
    }

    $directories = @(Get-ChildItem -LiteralPath $backupContainer -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($directories.Count -le $KeepLatest) {
        return @()
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in ($directories | Select-Object -Skip $KeepLatest)) {
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        $removed.Add($directory.FullName) | Out-Null
    }

    return @($removed)
}

function Write-ManagedState {
    param(
        [string]$ProjectPath,
        [string[]]$ManagedEntries,
        [int]$BackupKeepCount
    )

    $statePath = Get-ManagedStatePath -ProjectPath $ProjectPath
    $state = [ordered]@{
        version = 1
        updatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        managedEntries = $ManagedEntries
        backupKeepCount = $BackupKeepCount
    }

    $json = $state | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $statePath -Value $json -Encoding utf8
}

function Write-ProjectIgnoreFile {
    param(
        [string]$ProjectPath,
        [string]$FileName
    )

    $ignorePath = Join-Path $ProjectPath $FileName
    $requiredEntries = @(
        "build/",
        ".cache/",
        ".cmake/",
        ".omx/",
        ".stm32-init-backup/",
        ".stm32-workspace-state.json",
        "CMakeCache.txt",
        "CMakeFiles/",
        "CMakeScripts/",
        "cmake_install.cmake",
        "compile_commands.json",
        "CTestTestfile.cmake",
        "Testing/",
        "Makefile",
        "install_manifest.txt",
        "CMakeUserPresets.json",
        "_deps/",
        "*.elf",
        "*.map",
        "*.bin",
        "*.hex",
        "*.obj",
        "*.o",
        "*.d",
        "*.log",
        "*.tmp",
        ".vscode/settings.json",
        ".vscode/*.code-snippets",
        ".vscode/ipch/"
    )

    $currentLines = @()
    if (Test-Path -LiteralPath $ignorePath) {
        $currentLines = @(Get-Content -LiteralPath $ignorePath)
    }

    $updated = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $currentLines) {
        $updated.Add($line) | Out-Null
    }

    foreach ($entry in $requiredEntries) {
        if ($entry -notin $updated) {
            $updated.Add($entry) | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $ignorePath)) {
        New-Item -ItemType File -Path $ignorePath -Force | Out-Null
    }

    [System.IO.File]::WriteAllLines($ignorePath, [string[]]$updated)
}

function Copy-TemplateDirectory {
    param(
        [string]$DirectoryName,
        [string]$ProjectPath
    )

    $source = Join-Path $TemplateRoot $DirectoryName
    $destination = Join-Path $ProjectPath $DirectoryName

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }

    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function Build-SettingsObject {
    param(
        [string]$TemplateSettingsPath,
        [string]$IocFileName,
        [string]$ProjectName,
        [string]$Device,
        [pscustomobject]$Tools
    )

    $settings = Get-Content -LiteralPath $TemplateSettingsPath -Raw | ConvertFrom-Json
    $settings.'cmake.buildDirectory' = '${workspaceFolder}/build/Debug'
    $settings.'stm32.projectRoot' = '${workspaceFolder}'
    $settings.'stm32.iocFile' = if ($IocFileName) { '${workspaceFolder}/' + $IocFileName } else { '' }
    $settings.'stm32.projectName' = $ProjectName
    $settings.'stm32.device' = $Device
    $settings.'stm32.interface' = 'swd'
    $settings.'stm32.runToEntryPoint' = 'main'
    $settings.'stm32.flashAddress' = '0x08000000'
    $settings.'stm32.cubeMxPath' = if ($Tools.CubeMX) { $Tools.CubeMX } else { '' }
    $settings.'stm32.cubeProgrammerPath' = if ($Tools.CubeProgrammer) { $Tools.CubeProgrammer } else { '' }
    $settings.'stm32.toolchainGdbPath' = if ($Tools.ArmGdb) { $Tools.ArmGdb } else { '' }
    $settings.'stm32.stlinkGdbServerPath' = if ($Tools.StlinkGdbServer) { $Tools.StlinkGdbServer } else { '' }
    return $settings
}

$resolvedProjectRoot = Resolve-WorkspacePath -Path $ProjectRoot
if ($resolvedProjectRoot -eq $TemplateRoot) {
    throw "不要在模板仓库自身上运行初始化脚本。请把 -ProjectRoot 指向目标 STM32 工程目录。"
}

$done = [System.Collections.Generic.List[string]]::new()
$fixed = [System.Collections.Generic.List[string]]::new()
$missing = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

$iocFiles = @(Get-WorkspaceFiles -Root $resolvedProjectRoot -Filter *.ioc)
if ($iocFiles.Count -gt 1) {
    $iocList = ($iocFiles | Select-Object -ExpandProperty FullName) -join "; "
    throw "检测到多个 .ioc 文件，无法自动决定使用哪个：$iocList"
}

$iocPath = if ($iocFiles.Count -eq 1) { $iocFiles[0].FullName } else { $null }
$rootCMakeListsPath = Join-Path $resolvedProjectRoot "CMakeLists.txt"
if (-not (Test-Path -LiteralPath $rootCMakeListsPath)) {
    $rootCMakeListsPath = $null
}

$iocProjectName = if ($iocPath) { Get-IocValue -IocPath $iocPath -Key "ProjectManager.ProjectName" } else { $null }
$iocDevice = if ($iocPath) { Get-IocValue -IocPath $iocPath -Key "Mcu.CPN" } else { $null }
if (-not $iocDevice -and $iocPath) {
    $iocDevice = Get-IocValue -IocPath $iocPath -Key "Mcu.Name"
}
$iocFamily = if ($iocPath) { Get-IocValue -IocPath $iocPath -Key "Mcu.Family" } else { $null }
$cmakeProjectName = if ($rootCMakeListsPath) { Get-CMakeProjectName -CMakeListsPath $rootCMakeListsPath } else { $null }

$rawProjectName = $iocProjectName
if (-not $rawProjectName) {
    $rawProjectName = $cmakeProjectName
}
if (-not $rawProjectName -and $iocPath) {
    $rawProjectName = [System.IO.Path]::GetFileNameWithoutExtension($iocPath)
}
if (-not $rawProjectName) {
    $rawProjectName = Split-Path -Leaf $resolvedProjectRoot
}

$safeProjectName = ConvertTo-SafeProjectName -Name $rawProjectName

$deviceCandidate = $iocDevice
if (-not $deviceCandidate) {
    $deviceCandidate = Get-LinkerDeviceCandidate -Root $resolvedProjectRoot
}
if (-not $deviceCandidate) {
    $deviceCandidate = Get-StartupDeviceCandidate -Root $resolvedProjectRoot
}

$familyCandidate = $iocFamily
if (-not $familyCandidate) {
    $familyCandidate = Get-FamilyCandidate -Root $resolvedProjectRoot
}

$concreteDevice = if (Test-ConcreteDevice -Device $deviceCandidate) { $deviceCandidate } else { "" }
if (-not $concreteDevice -and $deviceCandidate) {
    Add-UniqueItem -List $missing -Value ("只能推断到芯片族，无法确认具体器件：{0}" -f $deviceCandidate)
}
if (-not $concreteDevice -and -not $deviceCandidate) {
    if ($familyCandidate) {
        Add-UniqueItem -List $missing -Value ("已识别芯片族：{0}，但无法确认具体器件型号。" -f $familyCandidate)
    } else {
        Add-UniqueItem -List $missing -Value "没有找到可用于调试配置的具体 STM32 器件型号。"
    }
}

$projectFolderName = Split-Path -Leaf $resolvedProjectRoot
if ($projectFolderName -match '[^A-Za-z0-9._ -]') {
    Add-UniqueItem -List $warnings -Value ("目录名包含不稳字符，建议后续手动整理：{0}" -f $projectFolderName)
}

$tools = Get-Stm32ToolPaths
$requiredTools = [ordered]@{
    "CMake" = $tools.CMake
    "Ninja" = $tools.Ninja
    "arm-none-eabi-gcc" = $tools.ArmGcc
    "arm-none-eabi-gdb" = $tools.ArmGdb
    "STM32CubeProgrammer" = $tools.CubeProgrammer
    "ST-LINK_gdbserver" = $tools.StlinkGdbServer
}

if ($iocPath) {
    $requiredTools["STM32CubeMX"] = $tools.CubeMX
}

$missingTools = @($requiredTools.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
if ($missingTools.Count -gt 0) {
    throw "缺少关键工具：$($missingTools -join ', ')。未写入任何项目配置。"
}

$removedManagedEntries = @(Remove-StaleManagedEntries -ProjectPath $resolvedProjectRoot -CurrentEntries $CurrentManagedEntries)
foreach ($entry in $removedManagedEntries) {
    Add-UniqueItem -List $fixed -Value ("已清理旧托管内容：{0}" -f $entry)
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $resolvedProjectRoot (".stm32-init-backup\{0}" -f $timestamp)
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

Backup-Path -SourcePath (Join-Path $resolvedProjectRoot ".vscode") -BackupRoot $backupRoot
Backup-Path -SourcePath (Join-Path $resolvedProjectRoot "tools") -BackupRoot $backupRoot
Backup-File -FilePath (Join-Path $resolvedProjectRoot ".gitignore") -BackupRoot $backupRoot
Backup-File -FilePath (Join-Path $resolvedProjectRoot ".ignore") -BackupRoot $backupRoot
Backup-File -FilePath (Join-Path $resolvedProjectRoot ".clangd") -BackupRoot $backupRoot
Backup-File -FilePath (Get-ManagedStatePath -ProjectPath $resolvedProjectRoot) -BackupRoot $backupRoot
if ($iocPath) {
    Backup-File -FilePath $iocPath -BackupRoot $backupRoot
}
if ($rootCMakeListsPath) {
    Backup-File -FilePath $rootCMakeListsPath -BackupRoot $backupRoot
}
Add-UniqueItem -List $done -Value ("已创建备份目录：{0}" -f $backupRoot)

foreach ($entry in @(Remove-ManagedEntries -ProjectPath $resolvedProjectRoot -Entries $CurrentManagedEntries)) {
    Add-UniqueItem -List $fixed -Value ("已删除旧托管内容：{0}" -f $entry)
}

Copy-TemplateDirectory -DirectoryName ".vscode" -ProjectPath $resolvedProjectRoot
Copy-TemplateDirectory -DirectoryName "tools" -ProjectPath $resolvedProjectRoot
Copy-Item -LiteralPath (Join-Path $TemplateRoot ".clangd") -Destination (Join-Path $resolvedProjectRoot ".clangd") -Force
Add-UniqueItem -List $done -Value "已写入模板 .vscode、tools 和 .clangd。"

if ($iocPath) {
    $newIocFileName = "{0}.ioc" -f $safeProjectName
    Set-IocProjectMetadata -IocPath $iocPath -ProjectName $safeProjectName -ProjectFileName $newIocFileName

    $currentIocFileName = Split-Path -Leaf $iocPath
    if ($currentIocFileName -ne $newIocFileName) {
        $newIocPath = Join-Path (Split-Path -Parent $iocPath) $newIocFileName
        Move-Item -LiteralPath $iocPath -Destination $newIocPath -Force
        $iocPath = $newIocPath
        Add-UniqueItem -List $fixed -Value ("已修正 .ioc 文件名：{0}" -f $newIocFileName)
    }

    if ($rawProjectName -ne $safeProjectName) {
        Add-UniqueItem -List $fixed -Value ("已修正项目名：{0} -> {1}" -f $rawProjectName, $safeProjectName)
    }
}

if ($rootCMakeListsPath -and (Set-CMakeProjectName -CMakeListsPath $rootCMakeListsPath -ProjectName $safeProjectName)) {
    Add-UniqueItem -List $fixed -Value "已同步更新根 CMakeLists.txt 的项目名。"
}

if (-not $rootCMakeListsPath -and $iocPath) {
    & (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32CubeMXGenerate.ps1") `
        -WorkspaceRoot $resolvedProjectRoot `
        -ProjectRoot $resolvedProjectRoot `
        -IocPath $iocPath `
        -ProjectName $safeProjectName

    $rootCMakeListsPath = Join-Path $resolvedProjectRoot "CMakeLists.txt"
    if (Test-Path -LiteralPath $rootCMakeListsPath) {
        Add-UniqueItem -List $done -Value "已通过 CubeMX 生成 CMake 工程骨架。"
    } else {
        Add-UniqueItem -List $missing -Value "CubeMX 已执行，但仍未生成根 CMakeLists.txt。"
    }
}

$settingsPath = Join-Path $resolvedProjectRoot ".vscode\settings.json"
$settingsTemplatePath = Join-Path $resolvedProjectRoot ".vscode\settings.template.json"
$iocFileNameForSettings = if ($iocPath) { Split-Path -Leaf $iocPath } else { "" }
$settings = Build-SettingsObject `
    -TemplateSettingsPath $settingsTemplatePath `
    -IocFileName $iocFileNameForSettings `
    -ProjectName $safeProjectName `
    -Device $concreteDevice `
    -Tools $tools

$settingsJson = $settings | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $settingsPath -Value $settingsJson -Encoding utf8
Add-UniqueItem -List $done -Value "已生成本地 .vscode/settings.json。"

Write-ProjectIgnoreFile -ProjectPath $resolvedProjectRoot -FileName ".gitignore"
Write-ProjectIgnoreFile -ProjectPath $resolvedProjectRoot -FileName ".ignore"
Add-UniqueItem -List $done -Value "已更新 .gitignore 和 .ignore。"

Write-ManagedState -ProjectPath $resolvedProjectRoot -ManagedEntries $CurrentManagedEntries -BackupKeepCount $ManagedBackupKeepCount
Add-UniqueItem -List $done -Value "已更新模板托管状态。"

& (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Doctor.ps1") -WorkspaceRoot $resolvedProjectRoot
Add-UniqueItem -List $done -Value "环境检查通过。"

if (-not $rootCMakeListsPath) {
    Add-UniqueItem -List $missing -Value "没有根 CMakeLists.txt，已完成模板补齐，但暂时无法自动编译验证。"
} else {
    & (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Build.ps1") `
        -Action Clean `
        -WorkspaceRoot $resolvedProjectRoot `
        -BuildDir (Join-Path $resolvedProjectRoot "build\Debug")

    & (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Build.ps1") `
        -Action Configure `
        -WorkspaceRoot $resolvedProjectRoot `
        -SourceDir $resolvedProjectRoot `
        -BuildDir (Join-Path $resolvedProjectRoot "build\Debug") `
        -BuildType Debug

    & (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Build.ps1") `
        -Action Build `
        -WorkspaceRoot $resolvedProjectRoot `
        -SourceDir $resolvedProjectRoot `
        -BuildDir (Join-Path $resolvedProjectRoot "build\Debug") `
        -BuildType Debug

    Add-UniqueItem -List $done -Value "已完成 Configure 和 Build 验证。"
}

$removedBackups = @(Prune-BackupDirectories -ProjectPath $resolvedProjectRoot -KeepLatest $ManagedBackupKeepCount)
if ($removedBackups.Count -gt 0) {
    Add-UniqueItem -List $done -Value ("已裁剪旧备份，仅保留最近 {0} 份。" -f $ManagedBackupKeepCount)
}

Write-Host ""
Write-Host "完成项"
foreach ($item in $done) {
    Write-Host "- $item"
}

if ($fixed.Count -gt 0) {
    Write-Host ""
    Write-Host "修正项"
    foreach ($item in $fixed) {
        Write-Host "- $item"
    }
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "提醒"
    foreach ($item in $warnings) {
        Write-Host "- $item"
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "仍缺项"
    foreach ($item in $missing) {
        Write-Host "- $item"
    }
}
