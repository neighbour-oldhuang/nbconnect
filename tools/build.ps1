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
#   .\tools\build.ps1 -App            # 打 AGC 上传包 .app，并先自增 versionCode
#   .\tools\build.ps1 -App -NoBump    # 打上传包但不动 versionCode（重打同一版时用）
#
# 日常开发把 build-profile.json5 的 signingConfig 留在 dev 即可（IDE Run 需要它）；
# -App 会临时换成发布证书（默认名 "default"，可用 -ReleaseSigningConfig 覆盖）
# 并在构建结束后还原。
#
# 路径可用环境变量覆盖：NBCONNECT_NETBIRD_DIR、NBCONNECT_DEVECO_DIR

[CmdletBinding()]
param(
    [switch]$SkipGo,
    [switch]$SkipHap,
    [switch]$Install,
    [switch]$App,
    [switch]$NoBump,
    [string]$ReleaseSigningConfig = 'default'
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

    # 管理端 peer 列表里的版本号取自 version.NetbirdVersion()，不注入就是 "development"
    # （面板显示 dev）。用 app.json5 的 versionName 作为唯一来源，保证两边一致。
    $appJson = Join-Path $projectDir 'AppScope\app.json5'
    Assert-Path $appJson 'AppScope/app.json5'
    $versionMatch = [regex]::Match((Get-Content $appJson -Raw), '"versionName"\s*:\s*"([^"]+)"')
    if (-not $versionMatch.Success) { throw "无法从 $appJson 解析 versionName" }
    $appVersion = $versionMatch.Groups[1].Value
    Write-Host ("      注入 NetBird 版本号 $appVersion") -ForegroundColor DarkGray

    Push-Location $netbirdDir
    try {
        # -tags harmony 是必需的：平台实现按该 build tag 分派。
        & go build -tags harmony -buildmode=c-archive `
            -ldflags "-X github.com/netbirdio/netbird/version.version=$appVersion" `
            -o (Join-Path $cppDir 'libnbharmony.a') .\client\harmony\
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

# versionCode 必须在调 hvigor 之前改：hvigor 在插件生效前就把 app.json5 读进内存模型，
# 构建过程中再改只会在下一次构建生效（实测产物 pack.info 仍是旧号），所以放在这里。
# AGC 不接受与已上传包相同的 versionCode，忘记抬号会在上传那一步才失败。
if ($App -and -not $NoBump) {
    $appJson = Join-Path $projectDir 'AppScope\app.json5'
    $rawApp = Get-Content $appJson -Raw
    $codeMatch = [regex]::Match($rawApp, '("versionCode"\s*:\s*)(\d+)')
    if (-not $codeMatch.Success) { throw "无法从 $appJson 解析 versionCode" }
    $currentCode = [int]$codeMatch.Groups[2].Value
    $nextCode = $currentCode + 1
    if ($nextCode -ge 2147483647) { throw "versionCode 越界: $nextCode" }
    ($rawApp -replace [regex]::Escape($codeMatch.Value), ($codeMatch.Groups[1].Value + $nextCode)) |
        Set-Content $appJson -NoNewline
    Write-Host ("      versionCode $currentCode -> $nextCode") -ForegroundColor DarkGray
}

$target = if ($App) { 'assembleApp' } else { 'assembleHap' }
Write-Host ("[2/3] 构建并签名 {0}..." -f $(if ($App) { 'AGC 上传包 (.app)' } else { 'HAP' })) -ForegroundColor Cyan
$env:DEVECO_SDK_HOME = $sdkDir
$env:JAVA_HOME = $jbr
$env:PATH = "$jbr\bin;$devecoDir\tools\node;$env:PATH"

# 日常开发要用 dev 证书（release profile 签名的包 hdc 装不上，IDE Run 会报 9568322
# "not trusted app source"），而上传 AGC 必须用发布证书。这里在打上传包时临时换过去，
# 构建完（含失败/中断）都还原，免得下次 Run 又被拒。
$buildProfile = Join-Path $projectDir 'build-profile.json5'
$signingBackup = $null
if ($App) {
    $rawProfile = Get-Content $buildProfile -Raw
    $signMatch = [regex]::Match($rawProfile, '("signingConfig"\s*:\s*")([^"]+)(")')
    if (-not $signMatch.Success) { throw "无法从 $buildProfile 解析 signingConfig" }
    if ($signMatch.Groups[2].Value -ne $ReleaseSigningConfig) {
        $signingBackup = $rawProfile
        $replacement = $signMatch.Groups[1].Value + $ReleaseSigningConfig + '"'
        ($rawProfile -replace [regex]::Escape($signMatch.Value), $replacement) |
            Set-Content $buildProfile -NoNewline
        Write-Host ("      signingConfig {0} -> {1}（构建后自动还原）" -f `
            $signMatch.Groups[2].Value, $ReleaseSigningConfig) -ForegroundColor DarkGray
    }
}

Push-Location $projectDir
try {
    & $hvigor --no-daemon $target
    if ($LASTEXITCODE -ne 0) { throw "$target 失败（退出码 $LASTEXITCODE）" }
} finally {
    Pop-Location
    if ($signingBackup) {
        Set-Content $buildProfile $signingBackup -NoNewline
        Write-Host '      signingConfig 已还原' -ForegroundColor DarkGray
    }
}

if ($App) {
    $bundle = Join-Path $projectDir 'build\outputs\default\nbconnect-default-signed.app'
    Assert-Path $bundle '签名后的 .app'
    Write-Host ("      {0}" -f $bundle) -ForegroundColor DarkGray
    Write-Host '[3/3] .app 用于上传 AGC，release profile 签名的包 hdc 装不上，跳过装机' -ForegroundColor DarkGray
    return
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
