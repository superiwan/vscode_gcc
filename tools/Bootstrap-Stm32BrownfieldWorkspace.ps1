[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\STM32.Common.ps1"

$TemplateRoot = Split-Path -Parent $PSScriptRoot
$SkipNames = @(".git", ".vscode", "tools", "build", ".stm32-init-backup", ".stm32-brownfield-backup", ".omx")
$BrownfieldStateFileName = ".stm32-brownfield-state.json"
$BrownfieldBackupDirName = ".stm32-brownfield-backup"
$ManagedBackupKeepCount = 3
$LegacyProjectPatterns = @("*.uvprojx", "*.ewp", "*.cproject", "*.project")
$KnownSourceRootNames = @("Core", "Drivers", "Driver", "Middlewares", "Libraries", "Library", "User", "Users", "Src", "Source", "Sources", "Application", "App", "BSP", "CMSIS", "Start", "Startup", "System", "cmake")
$StaticManagedEntries = @(
    ".vscode",
    "tools",
    ".clangd",
    ".gitignore",
    ".ignore",
    $BrownfieldStateFileName,
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

    foreach ($segment in ($relativePath -split '[\\/]')) {
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

function Get-RelativeProjectPath {
    param(
        [string]$ProjectRoot,
        [string]$Path
    )

    $fullRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootUri = New-Object System.Uri($fullRoot)
    $pathUri = New-Object System.Uri($fullPath)
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function ConvertTo-CMakeRelativePath {
    param(
        [string]$ProjectRoot,
        [string]$Path
    )

    return (Get-RelativeProjectPath -ProjectRoot $ProjectRoot -Path $Path).Replace('\', '/')
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

function Get-RootIocFile {
    param(
        [string]$ProjectPath
    )

    $iocFiles = @(Get-ChildItem -LiteralPath $ProjectPath -Filter *.ioc -File -ErrorAction SilentlyContinue)
    if ($iocFiles.Count -gt 1) {
        throw "检测到多个根目录 .ioc 文件，无法自动决定使用哪个。"
    }

    if ($iocFiles.Count -eq 1) {
        return $iocFiles[0].FullName
    }

    return $null
}

function Get-RootCMakeProjectName {
    param(
        [string]$CMakeListsPath
    )

    if (-not (Test-Path -LiteralPath $CMakeListsPath)) {
        return $null
    }

    $content = Get-Content -LiteralPath $CMakeListsPath -Raw
    $projectMatch = [regex]::Match($content, '(?im)^\s*project\s*\(\s*([^\s\)]+)')
    if ($projectMatch.Success) {
        return $projectMatch.Groups[1].Value.Trim('"')
    }

    $setMatch = [regex]::Match($content, '(?im)^\s*set\s*\(\s*CMAKE_PROJECT_NAME\s+([^\s\)]+)')
    if ($setMatch.Success) {
        return $setMatch.Groups[1].Value.Trim('"')
    }

    return $null
}

function Test-CMakeUsesArmToolchain {
    param(
        [string]$CMakeListsPath
    )

    if (-not (Test-Path -LiteralPath $CMakeListsPath)) {
        return $false
    }

    $content = Get-Content -LiteralPath $CMakeListsPath -Raw
    foreach ($pattern in @('CMAKE_TOOLCHAIN_FILE', 'arm-none-eabi', 'CMAKE_SYSTEM_NAME\s+Generic', 'gcc-arm-none-eabi\.cmake')) {
        if ($content -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-LegacyProjectFile {
    param(
        [string]$ProjectPath
    )

    $files = @()
    foreach ($pattern in $LegacyProjectPatterns) {
        $files += @(Get-WorkspaceFiles -Root $ProjectPath -Filter $pattern)
    }

    if (-not $files) {
        return $null
    }

    return ($files |
        Sort-Object @{ Expression = { (Get-RelativeProjectPath -ProjectRoot $ProjectPath -Path $_.FullName).Length } }, FullName |
        Select-Object -First 1 -ExpandProperty FullName)
}

function Split-DelimitedList {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value -split ';|,' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

function Resolve-LegacyPaths {
    param(
        [string[]]$Paths,
        [string]$BaseDirectory
    )

    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $Paths) {
        $candidate = $path.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $candidate = $candidate -replace '^\.\[\\/]', ''
        $candidate = $candidate -replace '^\$PROJ_DIR\$\[\\/]', ''
        $absolutePath = Resolve-OptionalPath -Path $candidate -BasePath $BaseDirectory
        if (Test-Path -LiteralPath $absolutePath) {
            Add-UniqueItem -List $resolved -Value $absolutePath
        }
    }

    return @($resolved)
}

function Get-KeilMetadata {
    param(
        [string]$ProjectFile
    )

    $content = Get-Content -LiteralPath $ProjectFile -Raw
    $projectDir = Split-Path -Parent $ProjectFile

    $targetName = [regex]::Match($content, '<TargetName>([^<]+)</TargetName>').Groups[1].Value.Trim()
    $device = [regex]::Match($content, '<Device>([^<]+)</Device>').Groups[1].Value.Trim()
    $cpu = [regex]::Match($content, '<Cpu>([^<]+)</Cpu>').Groups[1].Value.Trim()
    $outputName = [regex]::Match($content, '<OutputName>([^<]+)</OutputName>').Groups[1].Value.Trim()
    $defineMatches = [regex]::Matches($content, '<Define>([^<]*)</Define>') | ForEach-Object { $_.Groups[1].Value }
    $includeMatches = [regex]::Matches($content, '<IncludePath>([^<]*)</IncludePath>') | ForEach-Object { $_.Groups[1].Value }
    $filePathMatches = [regex]::Matches($content, '<FilePath>([^<]+)</FilePath>') | ForEach-Object { $_.Groups[1].Value.Trim() }

    $defines = [System.Collections.Generic.List[string]]::new()
    foreach ($defineBlock in $defineMatches) {
        foreach ($item in (Split-DelimitedList -Value $defineBlock)) {
            Add-UniqueItem -List $defines -Value $item
        }
    }

    $includeDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($includeBlock in $includeMatches) {
        foreach ($resolvedPath in (Resolve-LegacyPaths -Paths (Split-DelimitedList -Value $includeBlock) -BaseDirectory $projectDir)) {
            Add-UniqueItem -List $includeDirs -Value $resolvedPath
        }
    }

    $sourceFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($resolvedPath in (Resolve-LegacyPaths -Paths $filePathMatches -BaseDirectory $projectDir)) {
        if ([IO.Path]::GetExtension($resolvedPath).ToLowerInvariant() -in @(".c", ".cc", ".cpp", ".cxx", ".s", ".S", ".asm")) {
            Add-UniqueItem -List $sourceFiles -Value $resolvedPath
        }
    }

    $memory = $null
    $cpuMatch = [regex]::Match($cpu, 'IRAM\((0x[0-9A-Fa-f]+),(0x[0-9A-Fa-f]+)\)\s+IROM\((0x[0-9A-Fa-f]+),(0x[0-9A-Fa-f]+)\)')
    if ($cpuMatch.Success) {
        $memory = [pscustomobject]@{
            RamOrigin = $cpuMatch.Groups[1].Value
            RamLength = $cpuMatch.Groups[2].Value
            FlashOrigin = $cpuMatch.Groups[3].Value
            FlashLength = $cpuMatch.Groups[4].Value
        }
    }

    return [pscustomobject]@{
        Kind = "keil"
        ProjectFile = $ProjectFile
        ProjectName = if ($outputName) { $outputName } elseif ($targetName) { $targetName } else { [IO.Path]::GetFileNameWithoutExtension($ProjectFile) }
        Device = $device
        Cpu = $cpu
        Defines = @($defines)
        IncludeDirs = @($includeDirs)
        SourceFiles = @($sourceFiles)
        Memory = $memory
    }
}

function Get-IarMetadata {
    param(
        [string]$ProjectFile
    )

    $content = Get-Content -LiteralPath $ProjectFile -Raw
    $deviceMatch = [regex]::Match($content, 'STM32[A-Z0-9]+')
    return [pscustomobject]@{
        Kind = "iar"
        ProjectFile = $ProjectFile
        ProjectName = [IO.Path]::GetFileNameWithoutExtension($ProjectFile)
        Device = if ($deviceMatch.Success) { $deviceMatch.Value } else { $null }
        Cpu = $null
        Defines = @()
        IncludeDirs = @()
        SourceFiles = @()
        Memory = $null
    }
}

function Get-EclipseMetadata {
    param(
        [string]$ProjectFile
    )

    $content = Get-Content -LiteralPath $ProjectFile -Raw
    $deviceMatch = [regex]::Match($content, 'STM32[A-Z0-9]+')
    return [pscustomobject]@{
        Kind = "eclipse"
        ProjectFile = $ProjectFile
        ProjectName = [IO.Path]::GetFileNameWithoutExtension($ProjectFile)
        Device = if ($deviceMatch.Success) { $deviceMatch.Value } else { $null }
        Cpu = $null
        Defines = @()
        IncludeDirs = @()
        SourceFiles = @()
        Memory = $null
    }
}

function Get-LegacyMetadata {
    param(
        [string]$ProjectPath
    )

    $projectFile = Get-LegacyProjectFile -ProjectPath $ProjectPath
    if (-not $projectFile) {
        return $null
    }

    switch ([IO.Path]::GetExtension($projectFile).ToLowerInvariant()) {
        ".uvprojx" { return (Get-KeilMetadata -ProjectFile $projectFile) }
        ".ewp" { return (Get-IarMetadata -ProjectFile $projectFile) }
        default { return (Get-EclipseMetadata -ProjectFile $projectFile) }
    }
}

function Get-CommonSourceRootDirectories {
    param(
        [string]$ProjectPath
    )

    $dirs = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in (Get-ChildItem -LiteralPath $ProjectPath -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { -not (Test-SkippedPath -Root $ProjectPath -Path $_.FullName) })) {
        if ($directory.Name -in $KnownSourceRootNames) {
            Add-UniqueItem -List $dirs -Value $directory.FullName
        }
    }

    return @($dirs)
}

function Get-ScannedSourceFiles {
    param(
        [string]$ProjectPath
    )

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($rootDirectory in (Get-CommonSourceRootDirectories -ProjectPath $ProjectPath)) {
        foreach ($sourceFile in (Get-ChildItem -LiteralPath $rootDirectory -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".c", ".cc", ".cpp", ".cxx", ".s", ".S", ".asm") })) {
            Add-UniqueItem -List $files -Value $sourceFile.FullName
        }
    }

    return @($files)
}

function Get-ScannedIncludeDirs {
    param(
        [string]$ProjectPath
    )

    $dirs = [System.Collections.Generic.List[string]]::new()
    foreach ($rootDirectory in (Get-CommonSourceRootDirectories -ProjectPath $ProjectPath)) {
        foreach ($header in (Get-ChildItem -LiteralPath $rootDirectory -File -Recurse -Include *.h,*.hpp -ErrorAction SilentlyContinue)) {
            Add-UniqueItem -List $dirs -Value (Split-Path -Parent $header.FullName)
        }
    }

    return @($dirs)
}

function Get-ScannedStaticLibraries {
    param(
        [string]$ProjectPath
    )

    return @(Get-WorkspaceFiles -Root $ProjectPath -Filter *.a | Select-Object -ExpandProperty FullName)
}

function Get-UniqueStartupFile {
    param(
        [string[]]$SourceFiles,
        [string]$ProjectPath
    )

    $startupCandidates = @($SourceFiles | Where-Object { [IO.Path]::GetFileName($_) -match '^startup_.*\.(s|S|asm)$' })
    if ($startupCandidates.Count -eq 1) {
        return $startupCandidates[0]
    }

    $workspaceCandidates = @(Get-WorkspaceFiles -Root $ProjectPath -Filter startup_* | Where-Object { $_.Extension -in @(".s", ".S", ".asm") } | Select-Object -ExpandProperty FullName)
    if ($workspaceCandidates.Count -eq 1) {
        return $workspaceCandidates[0]
    }

    if ($workspaceCandidates.Count -gt 1) {
        return ($workspaceCandidates | Sort-Object { (Get-RelativeProjectPath -ProjectRoot $ProjectPath -Path $_).Length } | Select-Object -First 1)
    }

    return $null
}

function Get-LinkerScriptPath {
    param(
        [string]$ProjectPath
    )

    $linkerScripts = @(Get-WorkspaceFiles -Root $ProjectPath -Filter *.ld | Select-Object -ExpandProperty FullName)
    if ($linkerScripts.Count -eq 1) {
        return $linkerScripts[0]
    }

    if ($linkerScripts.Count -gt 1) {
        return ($linkerScripts | Sort-Object { (Get-RelativeProjectPath -ProjectRoot $ProjectPath -Path $_).Length } | Select-Object -First 1)
    }

    return $null
}

function Test-ArmasmStartupSyntax {
    param(
        [string]$StartupPath
    )

    if (-not (Test-Path -LiteralPath $StartupPath)) {
        return $false
    }

    $content = (Get-Content -LiteralPath $StartupPath -TotalCount 80) -join "`n"
    return ($content -match '(^|\r?\n)\s*AREA\s+' -or
            $content -match '(^|\r?\n)\s*[A-Za-z0-9_]+\s+PROC\b' -or
            $content -match '^\s*;')
}

function Get-CompileDefinitions {
    param(
        [pscustomobject]$LegacyMetadata,
        [string]$StartupPath,
        [string]$Device
    )

    $defines = [System.Collections.Generic.List[string]]::new()
    if ($LegacyMetadata) {
        foreach ($define in @($LegacyMetadata.Defines)) {
            Add-UniqueItem -List $defines -Value $define
        }
    }

    if ($Device -match '^STM32F10' -and -not ($defines -contains 'USE_STDPERIPH_DRIVER')) {
        Add-UniqueItem -List $defines -Value 'USE_STDPERIPH_DRIVER'
    }

    if ($StartupPath) {
        $startupName = [IO.Path]::GetFileNameWithoutExtension($StartupPath)
        $startupToken = $startupName -replace '^startup_', ''
        if ($startupToken -match '^stm32f10x_') {
            Add-UniqueItem -List $defines -Value $startupToken.ToUpperInvariant()
        } elseif ($startupToken -match '^stm32[a-z0-9]+xx$') {
            Add-UniqueItem -List $defines -Value ($startupToken.Substring(0, $startupToken.Length - 2).ToUpperInvariant() + 'xx')
        }
    }

    if ($Device -match '^STM32F4') {
        Add-UniqueItem -List $defines -Value 'USE_HAL_DRIVER'
        $deviceMacroMatch = [regex]::Match($Device, '^(STM32F4[0-9]{2})')
        if ($deviceMacroMatch.Success) {
            Add-UniqueItem -List $defines -Value ($deviceMacroMatch.Groups[1].Value.ToUpperInvariant() + 'xx')
        }
    }

    return @($defines)
}

function Get-CpuFlags {
    param(
        [string]$CpuDescription,
        [string]$Device
    )

    $flags = [System.Collections.Generic.List[string]]::new()
    if ($CpuDescription -match 'Cortex-M0\+') {
        Add-UniqueItem -List $flags -Value '-mcpu=cortex-m0plus'
    } elseif ($CpuDescription -match 'Cortex-M0') {
        Add-UniqueItem -List $flags -Value '-mcpu=cortex-m0'
    } elseif ($CpuDescription -match 'Cortex-M3') {
        Add-UniqueItem -List $flags -Value '-mcpu=cortex-m3'
    } elseif ($CpuDescription -match 'Cortex-M4') {
        Add-UniqueItem -List $flags -Value '-mcpu=cortex-m4'
    } elseif ($CpuDescription -match 'Cortex-M7') {
        Add-UniqueItem -List $flags -Value '-mcpu=cortex-m7'
    }

    if ($flags.Count -eq 0) {
        if ($Device -match '^STM32F10') {
            Add-UniqueItem -List $flags -Value '-mcpu=cortex-m3'
        } elseif ($Device -match '^STM32F4') {
            Add-UniqueItem -List $flags -Value '-mcpu=cortex-m4'
        } elseif ($Device -match '^STM32H7') {
            Add-UniqueItem -List $flags -Value '-mcpu=cortex-m7'
        }
    }

    Add-UniqueItem -List $flags -Value '-mthumb'

    if ($Device -match '^STM32F4(05|07|15|17|27|29|37|39|46)') {
        Add-UniqueItem -List $flags -Value '-mfpu=fpv4-sp-d16'
        Add-UniqueItem -List $flags -Value '-mfloat-abi=hard'
    }

    return @($flags)
}

function Write-ToolchainFile {
    param(
        [string]$ToolchainPath
    )

    $content = @'
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(_toolchain_search_roots
    "C:/Program Files (x86)/Arm GNU Toolchain arm-none-eabi/14.2 rel1/bin"
    "$ENV{LOCALAPPDATA}/stm32cube/bundles/gnu-tools-for-stm32/14.3.1+st.2/bin"
)

find_program(CMAKE_C_COMPILER arm-none-eabi-gcc HINTS ${_toolchain_search_roots} REQUIRED)
find_program(CMAKE_ASM_COMPILER arm-none-eabi-gcc HINTS ${_toolchain_search_roots} REQUIRED)
find_program(CMAKE_OBJCOPY arm-none-eabi-objcopy HINTS ${_toolchain_search_roots} REQUIRED)
find_program(CMAKE_SIZE arm-none-eabi-size HINTS ${_toolchain_search_roots} REQUIRED)

set(CMAKE_EXECUTABLE_SUFFIX ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_C ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_ASM ".elf")
'@

    Set-Content -LiteralPath $ToolchainPath -Value $content -Encoding utf8
}

function Write-LinkerScript {
    param(
        [string]$LinkerScriptPath,
        [pscustomobject]$Memory
    )

    $content = @"
ENTRY(Reset_Handler)

_estack = ORIGIN(RAM) + LENGTH(RAM);
_Min_Heap_Size = 0x200;
_Min_Stack_Size = 0x400;

MEMORY
{
  FLASH (rx)  : ORIGIN = $($Memory.FlashOrigin), LENGTH = $($Memory.FlashLength)
  RAM (xrw)   : ORIGIN = $($Memory.RamOrigin), LENGTH = $($Memory.RamLength)
}

SECTIONS
{
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } > FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP (*(.init))
    KEEP (*(.fini))
    . = ALIGN(4);
    _etext = .;
  } > FLASH

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    . = ALIGN(4);
  } > FLASH

  .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } > FLASH
  .ARM : { __exidx_start = .; *(.ARM.exidx*) __exidx_end = .; } > FLASH

  _sidata = LOADADDR(.data);
  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } > RAM AT> FLASH

  .bss :
  {
    _sbss = .;
    __bss_start__ = _sbss;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
    __bss_end__ = _ebss;
  } > RAM

  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE(end = .);
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } > RAM

  /DISCARD/ : { *(.note*) }
  .ARM.attributes 0 : { *(.ARM.attributes) }
}
"@

    Set-Content -LiteralPath $LinkerScriptPath -Value $content -Encoding utf8
}

function Get-MetadataFromScan {
    param(
        [string]$ProjectPath
    )

    $sourceFiles = @(Get-ScannedSourceFiles -ProjectPath $ProjectPath)
    $includeDirs = @(Get-ScannedIncludeDirs -ProjectPath $ProjectPath)

    return [pscustomobject]@{
        Kind = "scan"
        ProjectName = Split-Path -Leaf $ProjectPath
        Device = $null
        Cpu = $null
        Defines = @()
        IncludeDirs = $includeDirs
        SourceFiles = $sourceFiles
        StaticLibraries = @(Get-ScannedStaticLibraries -ProjectPath $ProjectPath)
        StartupPath = Get-UniqueStartupFile -SourceFiles $sourceFiles -ProjectPath $ProjectPath
        LinkerScriptPath = Get-LinkerScriptPath -ProjectPath $ProjectPath
        Memory = $null
    }
}

function Get-BrownfieldMetadata {
    param(
        [string]$ProjectPath
    )

    $legacyMetadata = Get-LegacyMetadata -ProjectPath $ProjectPath
    $scanMetadata = Get-MetadataFromScan -ProjectPath $ProjectPath

    $sourceFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($(if ($legacyMetadata) { $legacyMetadata.SourceFiles } else { @() })) + @($scanMetadata.SourceFiles)) {
        Add-UniqueItem -List $sourceFiles -Value $item
    }

    $includeDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($(if ($legacyMetadata) { $legacyMetadata.IncludeDirs } else { @() })) + @($scanMetadata.IncludeDirs)) {
        Add-UniqueItem -List $includeDirs -Value $item
    }

    $startupCandidates = [System.Collections.Generic.List[string]]::new()
    if ($scanMetadata.StartupPath) {
        Add-UniqueItem -List $startupCandidates -Value $scanMetadata.StartupPath
    }
    if ($legacyMetadata) {
        $legacyStartup = Get-UniqueStartupFile -SourceFiles @($legacyMetadata.SourceFiles) -ProjectPath $ProjectPath
        if ($legacyStartup) {
            Add-UniqueItem -List $startupCandidates -Value $legacyStartup
        }
    }

    $startupPath = $null
    foreach ($candidate in @($startupCandidates)) {
        if (-not (Test-ArmasmStartupSyntax -StartupPath $candidate)) {
            $startupPath = $candidate
            break
        }
    }
    if (-not $startupPath -and $startupCandidates.Count -gt 0) {
        $startupPath = $startupCandidates[0]
    }

    $filteredSourceFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($sourceFile in @($sourceFiles)) {
        if ([IO.Path]::GetFileName($sourceFile) -match '^startup_.*\.(s|S|asm)$') {
            continue
        }
        Add-UniqueItem -List $filteredSourceFiles -Value $sourceFile
    }
    if ($startupPath) {
        Add-UniqueItem -List $filteredSourceFiles -Value $startupPath
    }

    $linkerScriptPath = $scanMetadata.LinkerScriptPath
    $generatedLinkerPath = $null
    if (-not $linkerScriptPath -and $legacyMetadata -and $legacyMetadata.Memory) {
        $generatedLinkerPath = Join-Path $ProjectPath "cmake\generated-memory.ld"
        $linkerScriptPath = $generatedLinkerPath
    }

    $device = if ($legacyMetadata -and $legacyMetadata.Device) { $legacyMetadata.Device } else { $null }
    $projectName = if ($legacyMetadata -and $legacyMetadata.ProjectName) { $legacyMetadata.ProjectName } else { $scanMetadata.ProjectName }
    $cpu = if ($legacyMetadata) { $legacyMetadata.Cpu } else { $null }

    return [pscustomobject]@{
        ProjectName = (ConvertTo-SafeProjectName -Name $projectName)
        Device = $device
        Cpu = $cpu
        SourceFiles = @($filteredSourceFiles)
        IncludeDirs = @($includeDirs)
        StartupPath = $startupPath
        LinkerScriptPath = $linkerScriptPath
        GeneratedLinkerPath = $generatedLinkerPath
        Memory = if ($legacyMetadata) { $legacyMetadata.Memory } else { $null }
        Defines = (Get-CompileDefinitions -LegacyMetadata $legacyMetadata -StartupPath $startupPath -Device $device)
        CpuFlags = (Get-CpuFlags -CpuDescription $cpu -Device $device)
        StaticLibraries = @($scanMetadata.StaticLibraries)
    }
}

function New-BrownfieldCMakeLists {
    param(
        [string]$ProjectPath,
        [pscustomobject]$Metadata,
        [string]$ToolchainRelativePath,
        [string]$LinkerRelativePath
    )

    $sourceList = ($Metadata.SourceFiles | Sort-Object | ForEach-Object {
        '    ${PROJECT_ROOT}/' + (ConvertTo-CMakeRelativePath -ProjectRoot $ProjectPath -Path $_)
    }) -join "`r`n"

    $includeList = ($Metadata.IncludeDirs | Sort-Object | ForEach-Object {
        '    ${PROJECT_ROOT}/' + (ConvertTo-CMakeRelativePath -ProjectRoot $ProjectPath -Path $_)
    }) -join "`r`n"

    $defineList = ($Metadata.Defines | Sort-Object | ForEach-Object { "    $_" }) -join "`r`n"
    if ([string]::IsNullOrWhiteSpace($defineList)) {
        $defineList = "    /* no extra defines */"
    }

    $libraryList = ($Metadata.StaticLibraries | Sort-Object | ForEach-Object {
        '    ${PROJECT_ROOT}/' + (ConvertTo-CMakeRelativePath -ProjectRoot $ProjectPath -Path $_)
    }) -join "`r`n"
    $linkLibrariesBlock = ""
    if (-not [string]::IsNullOrWhiteSpace($libraryList)) {
        $linkLibrariesBlock = @"

target_link_libraries(`${PROJECT_NAME} PRIVATE
$libraryList
)
"@
    }

    $cpuFlagsString = ($Metadata.CpuFlags -join " ")
    $outputName = $Metadata.ProjectName

    return @"
cmake_minimum_required(VERSION 3.22)

set(CMAKE_TOOLCHAIN_FILE `${CMAKE_CURRENT_SOURCE_DIR}/$ToolchainRelativePath)

project($($Metadata.ProjectName) C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(PROJECT_ROOT `${CMAKE_CURRENT_SOURCE_DIR})
set(LINKER_SCRIPT `${PROJECT_ROOT}/$LinkerRelativePath)

add_executable(`${PROJECT_NAME}
$sourceList
)

set_target_properties(`${PROJECT_NAME} PROPERTIES SUFFIX ".elf")

target_include_directories(`${PROJECT_NAME} PRIVATE
$includeList
)

target_compile_definitions(`${PROJECT_NAME} PRIVATE
$defineList
)

target_compile_options(`${PROJECT_NAME} PRIVATE
    $cpuFlagsString
    -ffunction-sections
    -fdata-sections
    -Wall
    -Wextra
    -Wpedantic
    `$<`$<CONFIG:Debug>:-Og -g3>
    `$<`$<CONFIG:Release>:-O2>
)

target_link_options(`${PROJECT_NAME} PRIVATE
    $cpuFlagsString
    -T`${LINKER_SCRIPT}
    -specs=nano.specs
    -specs=nosys.specs
    -Wl,--gc-sections
    -Wl,--print-memory-usage
    -Wl,-Map=`${CMAKE_BINARY_DIR}/$outputName.map
)

$linkLibrariesBlock

add_custom_command(TARGET `${PROJECT_NAME} POST_BUILD
    COMMAND `${CMAKE_OBJCOPY} -O ihex `$<TARGET_FILE:`${PROJECT_NAME}> `${CMAKE_BINARY_DIR}/$outputName.hex
    COMMAND `${CMAKE_OBJCOPY} -O binary `$<TARGET_FILE:`${PROJECT_NAME}> `${CMAKE_BINARY_DIR}/$outputName.bin
    COMMAND `${CMAKE_SIZE} `$<TARGET_FILE:`${PROJECT_NAME}>
)
"@
}

function Set-ToolchainBootstrap {
    param(
        [string]$CMakeListsPath,
        [string]$ToolchainRelativePath
    )

    $content = Get-Content -LiteralPath $CMakeListsPath -Raw
    if ($content -match 'CMAKE_TOOLCHAIN_FILE|arm-none-eabi|gcc-arm-none-eabi\.cmake') {
        return $false
    }

    $bootstrap = @"
if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE "`${CMAKE_CURRENT_SOURCE_DIR}/$ToolchainRelativePath")
endif()

"@

    $updated = [regex]::Replace($content, '(^\s*cmake_minimum_required\s*\([^\r\n]+\)\s*)', "`$1`r`n$bootstrap", 1)
    if ($updated -eq $content) {
        $updated = $bootstrap + $content
    }

    Set-Content -LiteralPath $CMakeListsPath -Value $updated -Encoding utf8
    return $true
}

function Get-StatePath {
    param(
        [string]$ProjectPath
    )

    return (Join-Path $ProjectPath $BrownfieldStateFileName)
}

function Read-State {
    param(
        [string]$ProjectPath
    )

    $statePath = Get-StatePath -ProjectPath $ProjectPath
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

    $resolvedRoot = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
    $resolvedTarget = [IO.Path]::GetFullPath($targetPath)
    if (-not $resolvedTarget.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝删除超出工程目录的路径：$RelativePath"
    }

    Remove-Item -LiteralPath $targetPath -Recurse -Force
    return $true
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

function Write-State {
    param(
        [string]$ProjectPath,
        [string[]]$ManagedEntries
    )

    $statePath = Get-StatePath -ProjectPath $ProjectPath
    $state = [ordered]@{
        version = 1
        updatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        managedEntries = $ManagedEntries
        backupKeepCount = $ManagedBackupKeepCount
    }

    Set-Content -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 4) -Encoding utf8
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
        ".stm32-brownfield-backup/",
        ".stm32-workspace-state.json",
        ".stm32-brownfield-state.json",
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

function Prune-BackupDirectories {
    param(
        [string]$ProjectPath
    )

    $backupContainer = Join-Path $ProjectPath $BrownfieldBackupDirName
    if (-not (Test-Path -LiteralPath $backupContainer)) {
        return @()
    }

    $directories = @(Get-ChildItem -LiteralPath $backupContainer -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($directories.Count -le $ManagedBackupKeepCount) {
        return @()
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in ($directories | Select-Object -Skip $ManagedBackupKeepCount)) {
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        $removed.Add($directory.FullName) | Out-Null
    }

    return @($removed)
}

$resolvedProjectRoot = Resolve-WorkspacePath -Path $ProjectRoot
if ($resolvedProjectRoot -eq $TemplateRoot) {
    throw "不要在模板仓库自身上运行 Brownfield 引导脚本。"
}

$done = [System.Collections.Generic.List[string]]::new()
$fixed = [System.Collections.Generic.List[string]]::new()
$missing = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

$rootIocPath = Get-RootIocFile -ProjectPath $resolvedProjectRoot
if ($rootIocPath) {
    & (Join-Path $PSScriptRoot "Initialize-Stm32Workspace.ps1") -ProjectRoot $resolvedProjectRoot
    exit $LASTEXITCODE
}

$metadata = Get-BrownfieldMetadata -ProjectPath $resolvedProjectRoot
$rootCMakeListsPath = Join-Path $resolvedProjectRoot "CMakeLists.txt"
$hadRootCMake = Test-Path -LiteralPath $rootCMakeListsPath

if (-not $metadata.SourceFiles -or $metadata.SourceFiles.Count -eq 0) {
    throw "没有识别到可用于构建的源码文件，无法自动补齐 Brownfield 工程。"
}

if (-not $metadata.StartupPath) {
    throw "没有识别到 startup 文件，无法自动补齐 Brownfield 工程。"
}

if (Test-ArmasmStartupSyntax -StartupPath $metadata.StartupPath) {
    throw "检测到 ARMCC/Keil 风格的 startup 文件，当前缺少 GNU 兼容版本，脚本已保守停止。"
}

$generatedEntries = [System.Collections.Generic.List[string]]::new()
$cmakeDir = Join-Path $resolvedProjectRoot "cmake"
if (-not (Test-Path -LiteralPath $cmakeDir)) {
    New-Item -ItemType Directory -Path $cmakeDir | Out-Null
}

$toolchainPath = Join-Path $cmakeDir "gcc-arm-none-eabi.cmake"
if (-not (Test-Path -LiteralPath $toolchainPath)) {
    Write-ToolchainFile -ToolchainPath $toolchainPath
    Add-UniqueItem -List $generatedEntries -Value "cmake\gcc-arm-none-eabi.cmake"
}

if ($metadata.GeneratedLinkerPath) {
    if (-not $metadata.Memory) {
        throw "没有识别到链接脚本，也没有可用于生成链接脚本的内存布局信息。"
    }
    Add-UniqueItem -List $generatedEntries -Value (Get-RelativeProjectPath -ProjectRoot $resolvedProjectRoot -Path $metadata.GeneratedLinkerPath)
}

if (-not $metadata.LinkerScriptPath) {
    throw "没有识别到链接脚本，无法自动补齐 Brownfield 工程。"
}

$toolchainRelativePath = ConvertTo-CMakeRelativePath -ProjectRoot $resolvedProjectRoot -Path $toolchainPath
$linkerRelativePath = ConvertTo-CMakeRelativePath -ProjectRoot $resolvedProjectRoot -Path $metadata.LinkerScriptPath

if (-not $hadRootCMake) {
    $generatedCMake = New-BrownfieldCMakeLists -ProjectPath $resolvedProjectRoot -Metadata $metadata -ToolchainRelativePath $toolchainRelativePath -LinkerRelativePath $linkerRelativePath
    Set-Content -LiteralPath $rootCMakeListsPath -Value $generatedCMake -Encoding utf8
    Add-UniqueItem -List $generatedEntries -Value "CMakeLists.txt"
}

$currentManagedEntries = @($StaticManagedEntries + $generatedEntries)
$previousState = Read-State -ProjectPath $resolvedProjectRoot

$backupRoot = Join-Path $resolvedProjectRoot ($BrownfieldBackupDirName + "\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

foreach ($entry in @(".vscode", "tools", ".gitignore", ".ignore", ".clangd", $BrownfieldStateFileName, ".stm32-workspace-state.json", "CMakeLists.txt")) {
    $path = Join-Path $resolvedProjectRoot $entry
    if (Test-Path -LiteralPath $path -PathType Container) {
        Backup-Path -SourcePath $path -BackupRoot $backupRoot
    } else {
        Backup-File -FilePath $path -BackupRoot $backupRoot
    }
}

if ($previousState -and $previousState.managedEntries) {
    foreach ($entry in @($previousState.managedEntries)) {
        $path = Join-Path $resolvedProjectRoot $entry
        if (Test-Path -LiteralPath $path -PathType Container) {
            Backup-Path -SourcePath $path -BackupRoot $backupRoot
        } else {
            Backup-File -FilePath $path -BackupRoot $backupRoot
        }
    }
}

Add-UniqueItem -List $done -Value ("已创建 Brownfield 备份目录：{0}" -f $backupRoot)

if ($previousState -and $previousState.managedEntries) {
    foreach ($entry in @($previousState.managedEntries)) {
        if ($entry -notin $currentManagedEntries) {
            if (Remove-ManagedEntry -ProjectPath $resolvedProjectRoot -RelativePath $entry) {
                Add-UniqueItem -List $fixed -Value ("已清理旧托管内容：{0}" -f $entry)
            }
        }
    }
}

foreach ($entry in @($currentManagedEntries)) {
    if (Remove-ManagedEntry -ProjectPath $resolvedProjectRoot -RelativePath $entry) {
        Add-UniqueItem -List $fixed -Value ("已删除旧托管内容：{0}" -f $entry)
    }
}

if (-not (Test-Path -LiteralPath $toolchainPath)) {
    Write-ToolchainFile -ToolchainPath $toolchainPath
}

if ($metadata.GeneratedLinkerPath) {
    Write-LinkerScript -LinkerScriptPath $metadata.GeneratedLinkerPath -Memory $metadata.Memory
}

Copy-Item -LiteralPath (Join-Path $TemplateRoot ".clangd") -Destination (Join-Path $resolvedProjectRoot ".clangd") -Force
Copy-Item -LiteralPath (Join-Path $TemplateRoot ".vscode") -Destination (Join-Path $resolvedProjectRoot ".vscode") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $TemplateRoot "tools") -Destination (Join-Path $resolvedProjectRoot "tools") -Recurse -Force
Add-UniqueItem -List $done -Value "已写入 Brownfield 模板 .vscode、tools 和 .clangd。"

if ($hadRootCMake) {
    if (-not (Test-CMakeUsesArmToolchain -CMakeListsPath $rootCMakeListsPath)) {
        if (Set-ToolchainBootstrap -CMakeListsPath $rootCMakeListsPath -ToolchainRelativePath $toolchainRelativePath) {
            Add-UniqueItem -List $fixed -Value "已为现有根 CMakeLists.txt 补齐 ARM toolchain 入口。"
        }
    }
} else {
    $generatedCMake = New-BrownfieldCMakeLists -ProjectPath $resolvedProjectRoot -Metadata $metadata -ToolchainRelativePath $toolchainRelativePath -LinkerRelativePath $linkerRelativePath
    Set-Content -LiteralPath $rootCMakeListsPath -Value $generatedCMake -Encoding utf8
    Add-UniqueItem -List $done -Value "已生成新的根 CMakeLists.txt。"
}

$settingsTemplatePath = Join-Path $resolvedProjectRoot ".vscode\settings.template.json"
$settingsPath = Join-Path $resolvedProjectRoot ".vscode\settings.json"
$settings = Get-Content -LiteralPath $settingsTemplatePath -Raw | ConvertFrom-Json
$settings.'stm32.projectRoot' = '${workspaceFolder}'
$settings.'stm32.iocFile' = ''
$settings.'stm32.projectName' = $metadata.ProjectName
$settings.'stm32.device' = if (Test-ConcreteDevice -Device $metadata.Device) { $metadata.Device } else { '' }
$settings.'stm32.interface' = 'swd'
$settings.'stm32.runToEntryPoint' = 'main'
$settings.'stm32.flashAddress' = '0x08000000'
$tools = Get-Stm32ToolPaths
$settings.'stm32.cubeMxPath' = if ($tools.CubeMX) { $tools.CubeMX } else { '' }
$settings.'stm32.cubeProgrammerPath' = if ($tools.CubeProgrammer) { $tools.CubeProgrammer } else { '' }
$settings.'stm32.toolchainGdbPath' = if ($tools.ArmGdb) { $tools.ArmGdb } else { '' }
$settings.'stm32.stlinkGdbServerPath' = if ($tools.StlinkGdbServer) { $tools.StlinkGdbServer } else { '' }
Set-Content -LiteralPath $settingsPath -Value ($settings | ConvertTo-Json -Depth 6) -Encoding utf8
Add-UniqueItem -List $done -Value "已生成 Brownfield 本地 .vscode/settings.json。"

Write-ProjectIgnoreFile -ProjectPath $resolvedProjectRoot -FileName ".gitignore"
Write-ProjectIgnoreFile -ProjectPath $resolvedProjectRoot -FileName ".ignore"
Add-UniqueItem -List $done -Value "已更新 .gitignore 和 .ignore。"

Write-State -ProjectPath $resolvedProjectRoot -ManagedEntries $currentManagedEntries
Add-UniqueItem -List $done -Value "已更新 Brownfield 托管状态。"

& (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Doctor.ps1") -WorkspaceRoot $resolvedProjectRoot
Add-UniqueItem -List $done -Value "环境检查通过。"

if (Test-ConcreteDevice -Device $metadata.Device) {
    Add-UniqueItem -List $done -Value ("已识别芯片型号：{0}" -f $metadata.Device)
} elseif ($metadata.Device) {
    Add-UniqueItem -List $missing -Value ("只能推断到芯片族，无法确认具体器件：{0}" -f $metadata.Device)
} else {
    Add-UniqueItem -List $missing -Value "没有识别到具体芯片型号，调试配置已保留为空。"
}

& (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Build.ps1") -Action Clean -WorkspaceRoot $resolvedProjectRoot -BuildDir (Join-Path $resolvedProjectRoot "build\Debug")
& (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Build.ps1") -Action Configure -WorkspaceRoot $resolvedProjectRoot -SourceDir $resolvedProjectRoot -BuildDir (Join-Path $resolvedProjectRoot "build\Debug") -BuildType Debug
& (Join-Path $resolvedProjectRoot "tools\Invoke-Stm32Build.ps1") -Action Build -WorkspaceRoot $resolvedProjectRoot -SourceDir $resolvedProjectRoot -BuildDir (Join-Path $resolvedProjectRoot "build\Debug") -BuildType Debug
Add-UniqueItem -List $done -Value "已完成 Brownfield Configure 和 Build 验证。"

$removedBackups = @(Prune-BackupDirectories -ProjectPath $resolvedProjectRoot)
if ($removedBackups.Count -gt 0) {
    Add-UniqueItem -List $done -Value ("已裁剪旧 Brownfield 备份，仅保留最近 {0} 份。" -f $ManagedBackupKeepCount)
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
