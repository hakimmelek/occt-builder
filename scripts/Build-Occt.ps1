<#
.SYNOPSIS
    Builds any version of Open CASCADE Technology (OCCT) from sources, driven
    by a YAML configuration file.

.DESCRIPTION
    1. Extracts archives dropped in downloads/occt and downloads/3rdparty.
    2. Finds the OCCT sources and detects their version.
    3. Merges the matching version_overrides into the configuration.
    4. Configures, builds and installs OCCT with CMake.
    5. Writes occt-build-info.json (and occt-env.bat on Windows) into the
       install folder, so other projects (OCCTools) can consume the build.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Config
    YAML configuration file. Default: occt-build.yaml next to build_occt.bat.

.PARAMETER DryRun
    Print the resolved configuration and CMake commands, do not build.

.PARAMETER Clean
    Delete the build folder first (same as build.clean: true).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Config = '',
    [switch]$DryRun,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'YamlLite.ps1')

$IsWin = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

# Features that have no INSTALL_<NAME> option in OCCT.
$FeaturesWithoutInstall = @('opengl', 'd3d', 'xlib')

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Info([string]$Text) { Write-Host "    $Text" }

function Write-Warn([string]$Text) { Write-Host "    WARNING: $Text" -ForegroundColor Yellow }

function Resolve-BuilderPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function ConvertTo-CMakePath([string]$Path) { return $Path.Replace('\', '/') }

# Path relative to $Base when it lies inside it, otherwise the path unchanged.
# (Windows PowerShell 5.1 has no [System.IO.Path]::GetRelativePath.)
function Get-RelativePath([string]$Path, [string]$Base) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $prefix = [System.IO.Path]::GetFullPath($Base).TrimEnd('\', '/')
    $comparison = if ($IsWin) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($full.Equals($prefix, $comparison)) { return '.' }
    foreach ($sep in @('\', '/')) {
        if ($full.StartsWith($prefix + $sep, $comparison)) { return $full.Substring($prefix.Length + 1) }
    }
    return $full
}

# True when $Dir holds a CMake cache created for another build or source folder
# (e.g. the occt-builder folder was moved): CMake refuses to reuse it.
function Test-StaleCMakeCache([string]$Dir, [string]$SourceDir) {
    $cache = Join-Path $Dir 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cache)) { return $false }
    $text = Get-Content -Raw -LiteralPath $cache
    $cacheDir = [regex]::Match($text, '(?m)^CMAKE_CACHEFILE_DIR:INTERNAL=(.*?)\s*$').Groups[1].Value
    $homeDir = [regex]::Match($text, '(?m)^CMAKE_HOME_DIRECTORY:INTERNAL=(.*?)\s*$').Groups[1].Value
    if (-not $cacheDir -or -not $homeDir) { return $true }
    return ((Get-RelativePath $Dir $cacheDir) -ne '.') -or ((Get-RelativePath $SourceDir $homeDir) -ne '.')
}

function Get-Cfg($Map, [string]$Key, $Default) {
    $node = $Map
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node -or -not ($node -is [System.Collections.IDictionary]) -or -not $node.Contains($part)) {
            return $Default
        }
        $node = $node[$part]
    }
    if ($null -eq $node) { return $Default }
    return $node
}

function Merge-Map($Base, $Override) {
    foreach ($key in @($Override.Keys)) {
        $value = $Override[$key]
        if ($Base.Contains($key) -and $Base[$key] -is [System.Collections.IDictionary] -and $value -is [System.Collections.IDictionary]) {
            Merge-Map $Base[$key] $value
        }
        else {
            $Base[$key] = $value
        }
    }
}

function ConvertTo-CMakeValue($Value) {
    if ($Value -is [bool]) { if ($Value) { return 'ON' } else { return 'OFF' } }
    return [string]$Value
}

function Get-CpuCount {
    if ($env:NUMBER_OF_PROCESSORS) { return [int]$env:NUMBER_OF_PROCESSORS }
    return [System.Environment]::ProcessorCount
}

function Invoke-Logged([string]$Exe, [string[]]$Arguments, [string]$LogFile) {
    $display = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    Write-Host "> $Exe $display" -ForegroundColor DarkGray
    $writer = New-Object System.IO.StreamWriter($LogFile, $true)
    $prev = $ErrorActionPreference
    try {
        $writer.WriteLine("> $Exe $display")
        $ErrorActionPreference = 'Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            Write-Host $line
            $writer.WriteLine($line)
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
        $writer.Close()
    }
    if ($code -ne 0) { throw "Command failed (exit code $code). Full log: $LogFile" }
}

# -----------------------------------------------------------------------------
# Archives
# -----------------------------------------------------------------------------

function Find-7Zip {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Expand-Downloads([string]$From, [string]$To) {
    if (-not (Test-Path $From)) { return }
    $markers = Join-Path $To '.extracted'
    $archives = Get-ChildItem -LiteralPath $From -File | Where-Object { $_.Name -match '\.(zip|7z|tgz|tar\.gz|tar\.xz|tar\.bz2|tar)$' }
    foreach ($a in $archives) {
        $marker = Join-Path $markers ($a.Name + '.done')
        if (Test-Path $marker) { continue }
        Write-Info "Extracting $($a.Name) -> $To"
        New-Item -ItemType Directory -Force -Path $markers | Out-Null
        if ($a.Name -match '\.7z$') {
            $sevenZip = Find-7Zip
            if (-not $sevenZip) { throw "$($a.Name) is a .7z archive: install 7-Zip or extract it manually into $To" }
            & $sevenZip x -y "-o$To" $a.FullName | Out-Null
        }
        elseif ($a.Name -match '\.zip$' -and -not ($IsWin -and (Get-Command tar -ErrorAction SilentlyContinue))) {
            # GNU tar cannot read .zip files; Windows' bsdtar (tar.exe) can and is much faster
            $prevProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Expand-Archive -LiteralPath $a.FullName -DestinationPath $To -Force
            $ProgressPreference = $prevProgress
        }
        else {
            & tar -xf $a.FullName -C $To
            if ($LASTEXITCODE -ne 0) { throw "Failed to extract $($a.FullName)" }
        }
        Set-Content -LiteralPath $marker -Value (Get-Date -Format s)
    }
}

# -----------------------------------------------------------------------------
# OCCT sources
# -----------------------------------------------------------------------------

function Test-OcctSource([string]$Dir) {
    return (Test-Path (Join-Path $Dir 'CMakeLists.txt')) -and (Test-Path (Join-Path $Dir 'adm/cmake'))
}

function Get-OcctVersion([string]$Dir) {
    $text = $null
    $versionCmake = Join-Path $Dir 'adm/cmake/version.cmake'
    if (Test-Path $versionCmake) {
        $text = Get-Content -Raw -LiteralPath $versionCmake
        $pattern = '(?m)^\s*set\s*\(\s*OCC_VERSION_{0}\s+"?([^\s")]+)'
    }
    else {
        # OCCT <= 7.4 keeps the version in Standard_Version.hxx
        $hxx = Get-ChildItem -LiteralPath (Join-Path $Dir 'src') -Recurse -Filter 'Standard_Version.hxx' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hxx) {
            $text = Get-Content -Raw -LiteralPath $hxx.FullName
            $pattern = '(?m)^\s*#\s*define\s+OCC_VERSION_{0}\s+"?([^\s"]+)'
        }
    }
    if (-not $text) { return 'unknown' }
    $parts = @()
    foreach ($name in @('MAJOR', 'MINOR', 'MAINTENANCE')) {
        $m = [regex]::Match($text, ($pattern -f $name))
        if (-not $m.Success) { return 'unknown' }
        $parts += $m.Groups[1].Value
    }
    $version = $parts -join '.'
    $dev = [regex]::Match($text, ($pattern -f 'DEVELOPMENT'))
    if ($dev.Success) { $version += '.' + $dev.Groups[1].Value }
    return $version
}

function Find-OcctSources([string]$Dir) {
    $found = @()
    if (-not (Test-Path $Dir)) { return $found }
    foreach ($d1 in Get-ChildItem -LiteralPath $Dir -Directory) {
        if ($d1.Name.StartsWith('.')) { continue }
        if (Test-OcctSource $d1.FullName) { $found += $d1.FullName; continue }
        foreach ($d2 in Get-ChildItem -LiteralPath $d1.FullName -Directory) {
            if (Test-OcctSource $d2.FullName) { $found += $d2.FullName }
        }
    }
    return $found
}

function Resolve-OcctSource($Cfg) {
    $source = [string](Get-Cfg $Cfg 'occt.source' 'auto')
    $wanted = [string](Get-Cfg $Cfg 'occt.version' '')
    if ($source -ne 'auto' -and $source -ne '') {
        $path = $source
        if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path (Join-Path $Root 'sources') $path }
        $path = [System.IO.Path]::GetFullPath($path)
        if (-not (Test-OcctSource $path)) { throw "occt.source '$path' is not an OCCT source folder (no CMakeLists.txt + adm/cmake)" }
        return $path
    }
    $candidates = @(Find-OcctSources (Join-Path $Root 'sources'))
    if ($candidates.Count -eq 0) {
        throw "No OCCT sources found. Put the OCCT archive in downloads/occt/ or extract it in sources/."
    }
    if ($wanted) {
        $match = @($candidates | Where-Object { (Get-OcctVersion $_) -eq $wanted })
        if ($match.Count -eq 0) {
            $list = ($candidates | ForEach-Object { "$_ ($(Get-OcctVersion $_))" }) -join "`n      "
            throw "No OCCT sources with version $wanted. Found:`n      $list"
        }
        return $match[0]
    }
    if ($candidates.Count -gt 1) {
        $list = ($candidates | ForEach-Object { "$_ ($(Get-OcctVersion $_))" }) -join "`n      "
        throw "Several OCCT source folders found, set occt.version or occt.source in the config:`n      $list"
    }
    return $candidates[0]
}

# -----------------------------------------------------------------------------
# Third-party libraries
# -----------------------------------------------------------------------------

function Resolve-ThirdPartyDir($Cfg) {
    $dir = [string](Get-Cfg $Cfg 'third_party.dir' 'auto')
    if ($dir -ne 'auto' -and $dir -ne '') {
        $path = Resolve-BuilderPath $dir
        if (-not (Test-Path $path)) { throw "third_party.dir '$path' does not exist" }
        return $path
    }
    $base = Join-Path $Root 'third_party'
    if (-not (Test-Path $base)) { return $null }
    $children = @(Get-ChildItem -LiteralPath $base -Directory | Where-Object { -not $_.Name.StartsWith('.') })
    if ($children.Count -eq 0) { return $null }
    if (@($children | Where-Object { $_.Name -like 'freetype*' }).Count -gt 0) { return $base }
    # Prebuilt bundles usually extract into a single wrapper folder (3rdparty-vc14-64/...)
    foreach ($c in $children) {
        if (@(Get-ChildItem -LiteralPath $c.FullName -Directory | Where-Object { $_.Name -like 'freetype*' }).Count -gt 0) {
            return $c.FullName
        }
    }
    return $base
}

# -----------------------------------------------------------------------------
# Toolchain
# -----------------------------------------------------------------------------

$VsYears = @{ 15 = '2017'; 16 = '2019'; 17 = '2022'; 18 = '2026' }
$VsToolsets = @{ 15 = 'vc141'; 16 = 'vc142'; 17 = 'vc143'; 18 = 'vc145' }

function Find-VisualStudio([int]$Major) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $vsArgs = @('-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-format', 'json')
    if ($Major -gt 0) { $vsArgs += @('-version', "[$Major,$($Major + 1))") } else { $vsArgs += '-latest' }
    $json = ((& $vswhere @vsArgs) -join "`n").Trim()
    if (-not $json) { return $null }
    # Windows PowerShell 5.1 does not unroll JSON arrays in the pipeline
    $all = @()
    foreach ($item in (ConvertFrom-Json $json)) { $all += $item }
    if ($all.Count -eq 0) { return $null }
    $vs = $all | Sort-Object { [version]$_.installationVersion } -Descending | Select-Object -First 1
    return [pscustomobject]@{
        Path  = $vs.installationPath
        Major = ([version]$vs.installationVersion).Major
        Name  = $vs.displayName
    }
}

function Import-VsDevEnv($Vs, [string]$Arch) {
    $vcvars = Join-Path $Vs.Path 'VC\Auxiliary\Build\vcvarsall.bat'
    Write-Info "Loading compiler environment: $vcvars $Arch"
    $out = & cmd.exe /s /c "`"$vcvars`" $Arch >nul && set"
    if ($LASTEXITCODE -ne 0) { throw "vcvarsall.bat failed" }
    foreach ($line in $out) {
        if ($line -match '^([^=]+)=(.*)$') { [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
    }
}

function Find-CMake($Cfg, $Vs) {
    $cmake = [string](Get-Cfg $Cfg 'toolchain.cmake' 'auto')
    if ($cmake -ne 'auto' -and $cmake -ne '') {
        $path = Resolve-BuilderPath $cmake
        if (-not (Test-Path $path)) { throw "toolchain.cmake '$path' not found" }
        return $path
    }
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($Vs) {
        $bundled = Join-Path $Vs.Path 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        if (Test-Path $bundled) { return $bundled }
    }
    throw "CMake not found. Install CMake (https://cmake.org) or set toolchain.cmake in the config."
}

function Get-UnixCompilerTag {
    $cxx = $env:CXX
    if (-not $cxx) { $cxx = 'c++' }
    if (-not (Get-Command $cxx -ErrorAction SilentlyContinue)) { return 'cxx' }
    $banner = (& $cxx --version 2>$null | Select-Object -First 1)
    $ver = (& $cxx -dumpversion 2>$null)
    $major = ([string]$ver).Split('.')[0]
    if ($banner -match 'clang') { return "clang$major" }
    return "gcc$major"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    if (-not $Config) { $Config = Join-Path $Root 'occt-build.yaml' }
    $Config = Resolve-BuilderPath $Config
    Write-Step "Configuration: $Config"
    if (-not (Test-Path $Config)) { throw "Config file not found: $Config" }
    $cfg = Read-YamlFile $Config

    foreach ($d in @('downloads/occt', 'downloads/3rdparty', 'sources', 'third_party', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null
    }

    Write-Step 'Preparing sources'
    Expand-Downloads (Join-Path $Root 'downloads/occt') (Join-Path $Root 'sources')
    Expand-Downloads (Join-Path $Root 'downloads/3rdparty') (Join-Path $Root 'third_party')

    $sourceDir = Resolve-OcctSource $cfg
    $version = Get-OcctVersion $sourceDir
    Write-Info "OCCT sources : $sourceDir"
    Write-Info "OCCT version : $version"

    $overrides = Get-Cfg $cfg 'version_overrides' $null
    if ($overrides -is [System.Collections.IDictionary]) {
        foreach ($pattern in @($overrides.Keys)) {
            if ($version -like $pattern -and $overrides[$pattern] -is [System.Collections.IDictionary]) {
                Write-Info "Applying version_overrides '$pattern'"
                Merge-Map $cfg $overrides[$pattern]
            }
        }
    }

    Write-Step 'Toolchain'
    $arch = [string](Get-Cfg $cfg 'toolchain.architecture' 'x64')
    $generator = [string](Get-Cfg $cfg 'toolchain.generator' 'auto')
    $toolset = [string](Get-Cfg $cfg 'toolchain.toolset' '')
    $vs = $null
    if ($IsWin) {
        $vsMajor = 0
        if ($generator -match '^Visual Studio (\d+)') { $vsMajor = [int]$Matches[1] }
        $vs = Find-VisualStudio $vsMajor
        if (-not $vs) { throw 'Visual Studio with "Desktop development with C++" not found (vswhere). Install it, or check toolchain.generator.' }
        Write-Info "Visual Studio: $($vs.Name) ($($vs.Path))"
        if ($generator -eq 'auto') { $generator = "Visual Studio $($vs.Major) $($VsYears[$vs.Major])" }
    }
    elseif ($generator -eq 'auto') {
        if (Get-Command ninja -ErrorAction SilentlyContinue) { $generator = 'Ninja' } else { $generator = 'Unix Makefiles' }
    }
    $multiConfig = $generator -match '^Visual Studio|Multi-Config|^Xcode'
    $isVsGenerator = $generator -match '^Visual Studio'
    if ($IsWin -and -not $isVsGenerator) { Import-VsDevEnv $vs $arch }
    $cmake = Find-CMake $cfg $vs

    $compiler = [string](Get-Cfg $cfg 'output.compiler' '')
    if (-not $compiler) {
        if ($IsWin) {
            if ($toolset -match '^v(\d+)') { $compiler = "vc$($Matches[1])" } else { $compiler = $VsToolsets[$vs.Major] }
        }
        else { $compiler = Get-UnixCompilerTag }
    }
    $jobs = [int](Get-Cfg $cfg 'toolchain.jobs' 0)
    if ($jobs -le 0) { $jobs = Get-CpuCount }
    Write-Info "CMake        : $cmake"
    Write-Info "Generator    : $generator"
    Write-Info "Compiler tag : $compiler"
    Write-Info "Jobs         : $jobs"

    $libType = [string](Get-Cfg $cfg 'build.library_type' 'Shared')
    $configurations = @(Get-Cfg $cfg 'build.configurations' @('Release'))
    $name = [string](Get-Cfg $cfg 'output.name' 'occt-{version}-{compiler}-{arch}')
    $name = $name.Replace('{version}', $version).Replace('{compiler}', $compiler).Replace('{arch}', $arch).Replace('{libtype}', $libType.ToLower())
    $buildDir = Join-Path (Resolve-BuilderPath ([string](Get-Cfg $cfg 'output.build_root' 'build'))) $name
    $installDir = Join-Path (Resolve-BuilderPath ([string](Get-Cfg $cfg 'output.install_root' 'install'))) $name
    $logFile = Join-Path (Join-Path $Root 'logs') ("$name-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

    Write-Step 'Third-party libraries'
    $thirdPartyDir = Resolve-ThirdPartyDir $cfg
    if ($thirdPartyDir) { Write-Info "3RDPARTY_DIR : $thirdPartyDir" } else { Write-Info '3RDPARTY_DIR : (none, system libraries)' }
    if ($IsWin -and -not $thirdPartyDir -and -not (Get-Cfg $cfg 'third_party.paths' $null)) {
        Write-Warn 'third_party/ is empty: on Windows OCCT needs at least FreeType (see README, step 2)'
    }

    # --- CMake options -------------------------------------------------------
    $opts = [ordered]@{}
    $opts['INSTALL_DIR'] = ConvertTo-CMakePath $installDir
    $opts['BUILD_LIBRARY_TYPE'] = $libType
    $opts['BUILD_CPP_STANDARD'] = [string](Get-Cfg $cfg 'toolchain.cpp_standard' 'C++17')
    $opts['BUILD_USE_PCH'] = ConvertTo-CMakeValue ([bool](Get-Cfg $cfg 'build.use_pch' $true))
    $layout = [string](Get-Cfg $cfg 'output.layout' 'auto')
    if ($layout -ne 'auto' -and $layout -ne '') { $opts['INSTALL_DIR_LAYOUT'] = $layout }
    if ($thirdPartyDir) { $opts['3RDPARTY_DIR'] = ConvertTo-CMakePath $thirdPartyDir }

    $modules = Get-Cfg $cfg 'modules' ([ordered]@{})
    foreach ($m in @($modules.Keys)) { $opts["BUILD_MODULE_$m"] = ConvertTo-CMakeValue ([bool]$modules[$m]) }

    $installDlls = [bool](Get-Cfg $cfg 'third_party.install_dlls' $true)
    $features = Get-Cfg $cfg 'features' ([ordered]@{})
    foreach ($f in @($features.Keys)) {
        $upper = $f.ToUpper()
        $on = [bool]$features[$f]
        $opts["USE_$upper"] = ConvertTo-CMakeValue $on
        if ($on -and $installDlls -and $IsWin -and ($FeaturesWithoutInstall -notcontains $f)) { $opts["INSTALL_$upper"] = 'ON' }
        if ($on -and $IsWin -and $thirdPartyDir -and ($FeaturesWithoutInstall -notcontains $f)) {
            $explicit = Get-Cfg $cfg "third_party.paths.$f" ''
            $hit = @(Get-ChildItem -LiteralPath $thirdPartyDir -Directory | Where-Object { $_.Name -like "*$f*" })
            if (-not $explicit -and $hit.Count -eq 0) { Write-Warn "feature '$f' is on but no '*$f*' folder in $thirdPartyDir" }
        }
    }
    if ([bool](Get-Cfg $cfg 'modules.Draw' $false) -and $installDlls -and $IsWin) { $opts['INSTALL_TCL'] = 'ON' }
    if ($IsWin -and $installDlls -and $thirdPartyDir -and -not [bool](Get-Cfg $cfg 'features.freetype' $true)) {
        Write-Warn 'freetype is off: Visualization (needed by XCAF/STEP) may not build'
    }

    $paths = Get-Cfg $cfg 'third_party.paths' $null
    if ($paths -is [System.Collections.IDictionary]) {
        foreach ($p in @($paths.Keys)) {
            if ($paths[$p]) { $opts["3RDPARTY_$($p.ToUpper())_DIR"] = ConvertTo-CMakePath (Resolve-BuilderPath ([string]$paths[$p])) }
        }
    }

    $extra = Get-Cfg $cfg 'cmake_options' $null
    if ($extra -is [System.Collections.IDictionary]) {
        foreach ($k in @($extra.Keys)) { $opts[$k] = ConvertTo-CMakeValue $extra[$k] }
    }

    # --- Commands ------------------------------------------------------------
    $generatorArgs = @('-G', $generator)
    if ($isVsGenerator) {
        $generatorArgs += @('-A', $arch)
        if ($toolset) { $generatorArgs += @('-T', $toolset) }
    }
    $optionArgs = @($opts.Keys | ForEach-Object { "-D$_=$($opts[$_])" })

    $steps = @()
    if ($multiConfig) {
        $configureArgs = @('-S', $sourceDir, '-B', $buildDir) + $generatorArgs + $optionArgs
        $steps += , @{ Title = 'Configure'; Args = $configureArgs; Dir = $buildDir }
        foreach ($c in $configurations) {
            $steps += , @{ Title = "Build + install $c"; Args = @('--build', $buildDir, '--config', $c, '--target', 'install', '--parallel', "$jobs") }
        }
    }
    else {
        foreach ($c in $configurations) {
            $dir = Join-Path $buildDir $c
            $configureArgs = @('-S', $sourceDir, '-B', $dir) + $generatorArgs + $optionArgs + @("-DCMAKE_BUILD_TYPE=$c")
            $steps += , @{ Title = "Configure $c"; Args = $configureArgs; Dir = $dir }
            $steps += , @{ Title = "Build + install $c"; Args = @('--build', $dir, '--target', 'install', '--parallel', "$jobs") }
        }
    }

    Write-Step 'Summary'
    Write-Info "Configurations: $($configurations -join ', ')"
    Write-Info "Build folder  : $buildDir"
    Write-Info "Install folder: $installDir"
    Write-Info "Log file      : $logFile"
    Write-Info 'CMake options :'
    foreach ($k in $opts.Keys) { Write-Info "    $k = $($opts[$k])" }

    if ($DryRun) {
        Write-Step 'Dry run: commands that would be executed'
        foreach ($s in $steps) { Write-Info "[$($s.Title)] `"$cmake`" $($s.Args -join ' ')" }
        exit 0
    }

    if ($Clean -or [bool](Get-Cfg $cfg 'build.clean' $false)) {
        if (Test-Path $buildDir) {
            Write-Step "Cleaning $buildDir"
            Remove-Item -Recurse -Force -LiteralPath $buildDir
        }
    }
    foreach ($s in $steps) {
        if ($s.Dir -and (Test-StaleCMakeCache $s.Dir $sourceDir)) {
            Write-Step "Cleaning $($s.Dir)"
            Write-Info 'Its CMake cache was created in another location (folder moved?), it cannot be reused.'
            Remove-Item -Recurse -Force -LiteralPath $s.Dir
        }
    }

    $started = Get-Date
    foreach ($s in $steps) {
        Write-Step $s.Title
        Invoke-Logged $cmake $s.Args $logFile
    }

    # --- Build info for consumers ---------------------------------------------
    Write-Step 'Writing build info'
    $cmakeConfig = Get-ChildItem -LiteralPath $installDir -Recurse -Filter 'OpenCASCADEConfig.cmake' -ErrorAction SilentlyContinue | Select-Object -First 1
    $kernelPattern = if ($IsWin) { 'TKernel.dll' } else { 'libTKernel.*' }
    $binDirs = @(Get-ChildItem -LiteralPath $installDir -Recurse -Filter $kernelPattern -ErrorAction SilentlyContinue |
        ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)

    # No absolute paths, so the install folder can be moved or copied:
    # cmake_dir and bin_dirs are relative to the install folder (where this file
    # lives), the other paths relative to the occt-builder folder.
    $toInstall = { param($p) ConvertTo-CMakePath (Get-RelativePath $p $installDir) }
    $toRoot = { param($p) ConvertTo-CMakePath (Get-RelativePath $p $Root) }
    $recordedOpts = [ordered]@{}
    foreach ($k in $opts.Keys) {
        $v = [string]$opts[$k]
        if ($k -eq 'INSTALL_DIR' -or $k -like '3RDPARTY_*DIR') { $v = & $toRoot $v }
        $recordedOpts[$k] = $v
    }
    $info = [ordered]@{
        builder         = 'occt-builder'
        occt_version    = $version
        cmake_dir       = if ($cmakeConfig) { & $toInstall $cmakeConfig.DirectoryName } else { $null }
        bin_dirs        = @($binDirs | ForEach-Object { & $toInstall $_ })
        source_dir      = & $toRoot $sourceDir
        configurations  = $configurations
        library_type    = $libType
        generator       = $generator
        compiler        = $compiler
        architecture    = $arch
        third_party_dir = if ($thirdPartyDir) { & $toRoot $thirdPartyDir } else { $null }
        cmake_options   = $recordedOpts
        config_file     = & $toRoot $Config
        built_at        = (Get-Date -Format s)
        duration_min    = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    }
    $infoFile = Join-Path $installDir 'occt-build-info.json'
    [System.IO.File]::WriteAllText($infoFile, ($info | ConvertTo-Json -Depth 5))
    Write-Info $infoFile

    if ($IsWin) {
        # Paths relative to the script itself (%~dp0), so the install folder can be moved
        $envLines = @('@echo off', 'rem Generated by occt-builder: adds the OCCT DLL folders to PATH',
            'for %%I in ("%~dp0.") do set "OCCT_ROOT=%%~fI"')
        foreach ($b in $binDirs) { $envLines += "set `"PATH=%OCCT_ROOT%\$((Get-RelativePath $b $installDir).Replace('/', '\'));%PATH%`"" }
        Set-Content -LiteralPath (Join-Path $installDir 'occt-env.bat') -Value $envLines -Encoding ASCII
    }

    Write-Step "Done: OCCT $version installed in $installDir"
    if ($cmakeConfig) { Write-Info "Use from CMake: -DOpenCASCADE_DIR=$(ConvertTo-CMakePath $cmakeConfig.DirectoryName)" }
    else { Write-Warn 'OpenCASCADEConfig.cmake not found in the install folder' }
    exit 0
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
