# NBConnect 一键构建脚本
#
# 做四件事：交叉编译 Go Core 为 c-archive、拷贝 .a/.h 到 N-API 模块、打签名 HAP、
# 可选装机。libnbharmony.a 有 113MB，超过 GitHub 单文件上限，不入库，所以每台新机器
# clone 后都要先跑一次本脚本（或至少跑 -SkipHap 生成 .a）才能构建。
#
# 用法：
#   .\tools\build.ps1                 # 全量：Go → 拷贝 → HAP
#   .\tools\build.ps1 -Install        # 再装到已连接的设备
#   .\tools\build.ps1 -SkipGo         # 只重打 HAP（改了 ArkTS/C++ 时用，快）
#   .\tools\build.ps1 -SkipHap        # 只出 .a（改了 Go 时先验证编译）
#
# 路径可用环境变量覆盖：NBCONNECT_NETBIRD_DIR、NBCONNECT_DEVECO_DIR

[CmdletBinding()]
param(
    [switch]$SkipGo,
    [switch]$SkipHap,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

$projectDir = Split-Path -Parent $PSScriptRoot
$netbirdDir = if ($env:NBCONNECT_NETBIRD_DIR) { $env:NBCONNECT_NETBIRD_DIR } else { Join-Path (Split-Path -Parent $projectDir) 'netbird' }
$devecoDir = if ($env:NBCONNECT_DEVECO_DIR) { $env:NBCONNECT_DEVECO_DIR } else { 'D:\Program Files\DevEco Studio' }

$sdkDir = Join-Path $devecoDir 'sdk'
$nativeDir = Join-Path $sdkDir 'default\openharmony\native'
$clang = Join-Path $nativeDir 'llvm\bin\clang.exe'
$sysroot = Join-Path $nativeDir 'sysroot'
$hdc = Join-Path $sdkDir 'default\openharmony\toolchains\hdc.exe'
$hvigor = Join-Path $devecoDir 'tools\hvigor\bin\hvigorw.bat'
# 系统 JDK 常缺 HmacPBESHA256，签名会失败；DevEco 自带的 JBR 没有这个问题。
$jbr = Join-Path $devecoDir 'jbr'
$cppDir = Join-Path $projectDir 'netbird\src\main\cpp'
$ccWrapper = Join-Path $projectDir 'tools\ohos-cc.bat'

function Assert-Path([string]$path, [string]$what) {
    if (-not (Test-Path $path)) {
        throw "$what 不存在：$path（可用环境变量 NBCONNECT_NETBIRD_DIR / NBCONNECT_DEVECO_DIR 覆盖路径）"
    }
}

Assert-Path $netbirdDir 'netbird 仓库'
Assert-Path $devecoDir 'DevEco Studio'

if (-not $SkipGo) {
    Assert-Path $clang 'OHOS NDK clang'
    Assert-Path $sysroot 'OHOS sysroot'
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        throw 'go 命令不可用，请先安装 Go 并加入 PATH'
    }

    # cgo 只接受不含空格的 CC，所以把带空格的 clang 路径包进一个 wrapper。
    @"
@echo off
REM 由 tools\build.ps1 生成：cgo 的 CC 不能带空格，这里固定 NDK clang 路径。
"$clang" -target aarch64-linux-ohos --sysroot="$sysroot" -D__MUSL__ %*
"@ | Set-Content -Path $ccWrapper -Encoding ASCII

    # -buildmode=c-archive 需要 ar，而 Windows 上没有；NDK 里的 llvm-ar 可以顶替，
    # 用一个同名 wrapper 放进 PATH 即可（否则报 running ar failed: "ar" not found）。
    $llvmAr = Join-Path $nativeDir 'llvm\bin\llvm-ar.exe'
    Assert-Path $llvmAr 'llvm-ar'
    $binDir = Join-Path $projectDir 'tools\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    @"
@echo off
REM 由 tools\build.ps1 生成：把 ar 指向 NDK 的 llvm-ar。
"$llvmAr" %*
"@ | Set-Content -Path (Join-Path $binDir 'ar.bat') -Encoding ASCII

    Write-Host '[1/3] 交叉编译 Go Core（aarch64-linux-ohos, -tags harmony）...' -ForegroundColor Cyan
    $env:CGO_ENABLED = '1'
    $env:GOOS = 'linux'
    $env:GOARCH = 'arm64'
    $env:CC = $ccWrapper
    $env:PATH = "$binDir;$env:PATH"
    Push-Location $netbirdDir
    try {
        # -tags harmony 是必需的：平台实现按该 build tag 分派。
        & go build -tags harmony -buildmode=c-archive -o (Join-Path $cppDir 'libnbharmony.a') .\client\harmony\
        if ($LASTEXITCODE -ne 0) { throw "go build 失败（退出码 $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
    $archive = Get-Item (Join-Path $cppDir 'libnbharmony.a')
    Write-Host ("      libnbharmony.a {0:N0} 字节" -f $archive.Length) -ForegroundColor DarkGray
} else {
    Assert-Path (Join-Path $cppDir 'libnbharmony.a') 'libnbharmony.a（先不加 -SkipGo 跑一次）'
    Write-Host '[1/3] 跳过 Go 构建' -ForegroundColor DarkGray
}

if ($SkipHap) {
    Write-Host '[2/3] 跳过 HAP 构建' -ForegroundColor DarkGray
    return
}

Assert-Path $hvigor 'hvigorw'
Assert-Path $jbr 'DevEco JBR'

Write-Host '[2/3] 构建并签名 HAP...' -ForegroundColor Cyan
$env:DEVECO_SDK_HOME = $sdkDir
$env:JAVA_HOME = $jbr
$env:PATH = "$jbr\bin;$devecoDir\tools\node;$env:PATH"
Push-Location $projectDir
try {
    & $hvigor --no-daemon assembleHap
    if ($LASTEXITCODE -ne 0) { throw "assembleHap 失败（退出码 $LASTEXITCODE）" }
} finally {
    Pop-Location
}

$hap = Join-Path $projectDir 'netbird\build\default\outputs\default\netbird-default-signed.hap'
Assert-Path $hap '签名后的 HAP'
Write-Host ("      {0}" -f $hap) -ForegroundColor DarkGray

if (-not $Install) {
    Write-Host '[3/3] 未指定 -Install，跳过装机' -ForegroundColor DarkGray
    return
}

Assert-Path $hdc 'hdc'
Write-Host '[3/3] 安装到设备...' -ForegroundColor Cyan
$targets = & $hdc list targets
if (-not $targets -or $targets -match '\[Empty\]') {
    throw '没有已连接的设备（hdc list targets 为空）'
}
& $hdc install -r $hap
& $hdc shell aa start -a NetbirdAbility -b org.huangedehw.nbconnect | Out-Null
Write-Host '完成' -ForegroundColor Green
