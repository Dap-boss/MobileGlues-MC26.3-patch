# MobileGlues 26.3 补丁构建脚本（Windows PowerShell）
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#   .\build.ps1 -Abi arm64-v8a -Ndk "C:\Android\ndk\27.0.12077973"
#
# 依赖: git, cmake(>=3.22), ninja, Android NDK 27

param(
    [string]$Abi = "arm64-v8a",
    [string]$Platform = "android-21",
    [string]$BuildType = "Release",
    [string]$Ndk = $env:NDK,
    [string]$SrcDir = (Join-Path $PSScriptRoot "MobileGlues"),
    [string]$Ref = "97558a69157b033b890958b1e49258c5b51a80c6"
)

$ErrorActionPreference = "Stop"
$patchFile = Join-Path $PSScriptRoot "patches\mobileglues-mc26.3.patch"
$buildDir = Join-Path $PSScriptRoot "build-$Abi"

function Log($msg) { Write-Host "[build] $msg" -ForegroundColor Green }
function Die($msg) { Write-Host "[error] $msg" -ForegroundColor Red; exit 1 }

if (-not $Ndk) {
    if ($env:ANDROID_NDK_HOME) { $Ndk = $env:ANDROID_NDK_HOME }
    elseif ($env:ANDROID_HOME -and (Test-Path (Join-Path $env:ANDROID_HOME "ndk"))) {
        $Ndk = Get-ChildItem (Join-Path $env:ANDROID_HOME "ndk") -Directory |
            Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
    }
}
if (-not $Ndk -or -not (Test-Path $Ndk)) { Die "找不到 NDK，请用 -Ndk 指定，例如 -Ndk C:\Android\ndk\27.0.12077973" }

$toolchain = Join-Path $Ndk "build\cmake\android.toolchain.cmake"
if (-not (Test-Path $toolchain)) { Die "NDK 路径不对，缺少 $toolchain" }

foreach ($bin in @("git", "cmake", "ninja")) {
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) { Die "缺少 $bin" }
}

if (-not (Test-Path (Join-Path $SrcDir ".git"))) {
    Log "clone 上游到 $SrcDir"
    git clone --recursive https://github.com/MobileGL-Dev/MobileGlues.git $SrcDir
    git -C $SrcDir checkout $Ref
    git -C $SrcDir submodule update --init --recursive
} else {
    Log "复用已有源码 $SrcDir"
}

git -C $SrcDir apply --check $patchFile 2>$null
if ($LASTEXITCODE -eq 0) {
    Log "应用补丁"
    git -C $SrcDir apply $patchFile
} else {
    Log "补丁已应用或无法应用，跳过"
}

Log "配置 ($Abi / $BuildType)"
cmake -S (Join-Path $SrcDir "MobileGlues-cpp") -B $buildDir -G Ninja `
    -DCMAKE_MAKE_PROGRAM=(Get-Command ninja).Source `
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" `
    -DANDROID_ABI="$Abi" `
    -DANDROID_PLATFORM="$Platform" `
    -DCMAKE_BUILD_TYPE="$BuildType" `
    -DANDROID_STL=c++_static
if ($LASTEXITCODE -ne 0) { Die "cmake 配置失败" }

Log "编译"
ninja -C $buildDir mobileglues
if ($LASTEXITCODE -ne 0) { Die "编译失败" }

$so = Join-Path $buildDir "libmobileglues.so"
if (-not (Test-Path $so)) { Die "产物不存在: $so" }

$strip = Get-ChildItem (Join-Path $Ndk "toolchains\llvm\prebuilt") -Directory |
    ForEach-Object { Join-Path $_.FullName "bin\llvm-strip.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($strip) { & $strip --strip-unneeded $so }

$sizeMb = [math]::Round((Get-Item $so).Length / 1MB, 1)
Log "完成: $so ($sizeMb MB)"
