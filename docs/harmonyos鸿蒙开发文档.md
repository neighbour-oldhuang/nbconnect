# NetBird HarmonyOS 开发文档

> 最后更新：2026-09-09
> 所有开发、构建、签名和设备调试均在 Windows 完成。

## 1. 当前里程碑

项目路径：

- HarmonyOS 工程：`D:\Code\nbconnect`
- NetBird Go 源码：`D:\Code\netbird`

已完成：

1. 真实 `client/internal.ConnectClient` 可在 HarmonyOS 初始化、查询和关闭；
2. Go `c-archive`、N-API、ArkTS、自动 TLS patch、签名 HAP 和真机运行闭环；
3. Harmony 专用 build tag 排除启动期 eBPF/Seccomp 崩溃；
4. `type: "vpn"` 的 VPN ExtensionAbility 已注册并可启动/停止；
5. VPN 进程可成功调用 `protectProcessNet()`；
6. 平台能力状态已接入 C ABI/N-API/Go Core；
7. UI ↔ `:vpn` 的同包定向 Dynamic CommonEvent 已升级为 IPC v2；状态与 `initialize/configure/connect/disconnect/shutdown` 逐请求控制、timeout、幂等重放和确认后停止均已接线；显式 Connect/Disconnect coordinator 的成功、幂等与失败 rollback 已通过无 VPN 真机 self-test；
8. Harmony fd-backed `tun.Device` 和专用 WireGuard interface factory 已实现；除 socketpair 自检外，已完成一次受控真实系统 VPN fd/raw packet/`O_NONBLOCK` 真机验证；
9. Go Core 已实现 fail-closed `ConnectClient.RunOnHarmony` 和 Harmony DNS/route/firewall/network monitor 平台分派；
10. ArkTS ↔ Go revision polling bridge 已完成：NetworkKit 非 VPN 接口进入 `ExternalIFaceDiscover`，Go desired address/route/DNS/search-domain/MTU snapshot 可构造纯内存 `VpnConfig`，并具备统一幂等 rollback；
11. context-aware late-fd 两阶段入口已完成：私有认证/config 恢复后，Extension 按标准顺序连接真实 Management、真实 Signal，再启动 Engine/唯一 Management Sync 并在 `TunDevice.Create` 等待平台 fd，支持 provide、context cancel、超时和 rollback；
12. Harmony provider 路径已在 fd wait 前启动唯一 management Sync：首个 NetworkMap 的 selected static routes 与 DNS/search domains 进入 prepared snapshot，原响应在 interface Up 后再回放；
13. 运行期 route/DNS desired revision 已实现 generation-safe 协调器：250ms debounce/coalescing、stale generation/revision/lease rejection、旧 duplicated fd release ack、fresh `ConnectClient` rebuild、显式 restart 和新 fd `fd-consumed` ack；
14. setup key 的 app-native `0600` 一次性导入、联网前删除、生成私钥 config 持久化和已有 config 无重复注册恢复已完成；
15. 真实 Management、Signal 和 single Sync 已在真机到达 `awaiting-fd`；生产显式 Connect 已完成 `create → versioned provide → matching fd-consumed`，Extension 启动本身仍不会 create；
16. `ManagementPrefetchOnly`/Signal mock branch 已删除；Management 与 Signal 使用 context-scoped runtime socket destination，同时保留各自原 gRPC/TLS authority；
17. Harmony 客户端强制广告 components NetworkMap v1，combined server 的现有 `server:` 配置需启用 `supportedSyncMessageVersions: 1`；
18. NetBird `0.78.0` SQLite 的 direct-peer Network Router 查询会被 `json_each([])` 交叉连接过滤；当前生产 workaround 是保留专用单-peer网关组 `nbconnect-router-workaround` 并让 Router 绑定该组，直到服务端 SQL 改为保留左表的 `LEFT JOIN`；
19. 新版 Network routes、真实网关数据面与后端 HTTP 已完成真机闭环，断开及最终进程清理通过；
20. Harmony 公网 P2P 已完成：只对 WireGuard/ICE UDP fd 使用 Harmony NDK 默认网络绑定，ICE 使用平台外部接口发现；routing peer 最终报告 `Connected/P2P`，双向 ICE candidate/type/endpoint 存在且 Tx/Rx active。
21. 生产 UI 已完成三态复刻与可信连接语义：`P2P 直连` 仅在隧道已建立、Peer 已连接、WireGuard 已握手且全部为直连时显示；混合路径显示 `VPN 已连接` 并给出 `直连 N · 中继 M`，连接详情只显示协议 `WireGuard`，逐 peer 的名称/IP/连接类型下沉到可展开的 Peers 列表。Core 新增 `p2pConnected`/`relayedConnected` 与 peer `details`（名称/IP/连接类型），WireGuard 公钥仍不外泄且 hilog 只输出计数。
22. 断开后重连已闭环。两个独立根因：服务端 `failed logging in peer: no peer auth`（本地私钥未在服务端注册，用可重复 setup key 重新注册后登录携带 `accountID`）；`ConnectClient` 用过一次不能再 Run，第二次会在 `netMgr.Wait` 处静默早退，诊断证据为 `engine run returned without tunnel fd after 1ms`。生产方案是 Disconnect 成功后主动停止 Extension，使下一次连接运行在全新 `:vpn` 进程，并修复 `STOPPED` 事件把 `extensionStarted` 误置为 true 的问题。真机连续两轮 `连接→断开→重连` 全部成功。

当前 `NbCoreConnect` 仍保留底层 fail-closed `-100` 边界，但远端 `CONTROL_CONNECT` 已不再调用它：宿主显式状态机复用 prepared-config `create → versioned provide → matching fd-consumed`，`CONTROL_DISCONNECT` 执行幂等 rollback。`PRODUCTION_ENABLE_EXPLICIT_VPN_CONNECT=true` 仅允许同包显式用户命令；Extension 启动仍只完成认证/preparation，自动 VPN event=0。两个调试 gate `DEBUG_ENABLE_REAL_VPN_FD` 与 `DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION` 均保持 `false`。

2026-09-08 最终真机闭环：components 协商 `advertisedVersion=1, syncVersion=1`，NetworkMap 为 `resources=3, routers=2, policies=3, decodedRoutes=3`；peer 摘要 `known=7, connected=2, withHandshake=2, routedPeers=2, assignedRoutes=3, Tx/Rx active`；平台 `routeCount=3, tunRead=15, tunWrite=5, tunInvalid=0`。用户提供的 HTTP 目标首次响应为重定向，Harmony NetStack 自动跟随后分别暴露 cURL 60/47；探测器未关闭 TLS 校验，而是对明文 HTTP 使用系统 TCP socket 只读取首个 HTTP/1.x 状态行，最终得到 `VPN_E2E_HTTP_PROBE_OK code=301`。Connect/Disconnect 均确认成功，系统 VPN `1 → 0`、failure=0、force-stop 后最终进程=0。普通状态和日志仍不包含凭据、地址、URL、route 内容、SNI、fd 或 packet。

## 2. 当前安全架构

HarmonyOS 实际将 VPN Extension 放到独立进程：

```text
UI 进程 org.huangedehw.nbconnect
  ArkTS 页面
  -> UI 进程 libnetbird.so
  -> UI 进程 Go Core（仅当前调试状态页）

VPN 进程 org.huangedehw.nbconnect:vpn
  NetbirdVpnExtensionAbility
  -> createVpnConnection(context)（只创建控制对象）
  -> protectProcessNet()
  -> app-private setup-key import（读取后联网前删除）/持久 config 恢复
  -> 真实 Management Login + 真实 Signal + single Sync
  -> NetworkKit 非 VPN 接口 observer
  -> HarmonyPlatformAdapter revision polling
  -> VPN 进程 libnetbird.so / Go Core
  -> 显式 preparation 时：management login -> prepared snapshot -> TunDevice.Create 等待 fd
  -> 运行期 desired 变化：debounce -> begin/old-fd-released -> host window -> restart/new fd-consumed
  -> 常规 polling 只构造纯内存 VpnConfig（DEBUG_ENABLE_REAL_VPN_FD=false）
  -> 同包生产显式 Connect：awaiting-fd/configReady -> create -> versioned provide -> matching fd-consumed
  -> 显式 Disconnect/异常/watchdog：幂等 destroy 与 rollback
```

UI 与 VPN 进程中的 N-API/Go 全局变量不是同一份。最新真机证据：

- UI PID：`6571`
- VPN Extension PID：`7343`

因此最终架构必须是：

```text
UI 控制面
  -> 跨进程命令/状态通道
  -> VPN Extension 进程
  -> 权威 Go Core
  -> fd-backed TUN adapter
```

真实 Core、TUN fd 和所有 NetBird 网络 socket 必须位于 VPN 进程；`protectProcessNet()` 仅对调用它的当前进程有效。

### 2.1 已实现的状态控制面

共享实现：

```text
netbird/src/main/ets/vpn/VpnIpc.ets
```

使用两个 Dynamic CommonEvent：

```text
org.huangedehw.nbconnect.event.VPN_COMMAND
org.huangedehw.nbconnect.event.VPN_STATUS
```

协议包固定为：

```ts
interface VpnIpcPacket {
  version: number;   // 当前为 2
  kind: string;      // status/control request/response 或 lifecycle event
  requestId: string;
  payload: string;
}
```

发布端设置 `bundleName=org.huangedehw.nbconnect`，订阅端设置 `publisherBundleName=org.huangedehw.nbconnect`，避免把当前控制面永久扩展为任意应用可发布/接收。当前流程：

1. UI 先订阅 `VPN_STATUS`；
2. VPN Extension 订阅 `VPN_COMMAND`；
3. `status-request/status-response` 继续返回 VPN 进程权威 `coreStatus()`；
4. `control-request/control-response` 支持 `initialize/configure/connect/disconnect/shutdown`，payload 严格只允许单一 `command`，不携带凭据或原始网络配置；
5. UI 在发布前登记 requestId pending，5 秒超时并校验 response command；Extension 串行执行，缓存最近 64 项，相同 requestId/command 幂等重放；
6. `connect` 直接返回 Core fail-closed `code=-100`；`shutdown` 先 rollback + `coreShutdown` 并逐请求确认，随后 UI 调用系统 API 停止 Extension。

真机已验证 initialize `code=0`、同 requestId 第二次 `duplicate=true`、configure 未就绪 `code=-409`、connect `code=-100`、shutdown `code=0`；全程 `VPN_CONNECTION_STATUS_CHANGED` 为 0。

HarmonyOS 的 common-event callback 声明参数为 `BusinessError`，但真机成功路径实际传入 `null`。原实现读取 `error.code` 导致 UI 与 VPN 两个进程同时出现：

```text
TypeError: Cannot read property code of null
```

所有 publish/subscribe/unsubscribe callback 现统一使用：

```ts
if (error !== null && error.code !== 0) {
  // error path
}
```

NetworkKit `NetConnection.register` 的真机成功回调与 CommonEvent 不同，实际传入 `undefined`；平台 adapter 必须使用：

```ts
if (error !== undefined && error !== null && error.code !== 0) {
  // error path
}
```

Extension 的 `onDestroy` 会尽力发布 `stopped`，但系统随后立即终止 `:vpn` 进程，不能把该异步事件作为唯一可靠确认。可靠停止条件是 `stopVpnExtensionAbility()` 成功返回且 `:vpn` PID 消失；UI 进程必须继续存活。

## 3. SDK 6.1.1(24) VPN API 结论

本机声明：

```text
D:\Program Files\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.vpnExtension.d.ts
D:\Program Files\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.app.ability.VpnExtensionAbility.d.ts
```

已确认：

| API | 版本 | 用途 |
|---|---:|---|
| `startVpnExtensionAbility(want)` | 11 | 启动第三方 VPN Extension |
| `stopVpnExtensionAbility(want)` | 11 | 停止 Extension |
| `createVpnConnection(context)` | 11 | 创建 VPN 控制对象 |
| `VpnConnection.create(config)` | 11 | 建立系统 VPN，返回 TUN fd |
| `protect(socketFd)` | 11 | 单 socket 绕过 VPN |
| `protectProcessNet()` | 22 | 保护当前 VPN 进程之后创建的全部 socket |
| `destroy()` | 11 | 销毁 VPN 网络 |

目标 SDK 为 24，因此优先采用 `protectProcessNet()`。必须在 Go 建立 management、signal、STUN、WireGuard 等 socket 之前执行。

`VpnConfig` 支持 addresses、routes、DNS、MTU、trusted/blocked applications。官方文档明确：`trustedApplications` 和 `blockedApplications` 不能同时配置。

模块 schema 中 VPN Extension 类型为：

```json
{
  "name": "NetbirdVpnExtensionAbility",
  "srcEntry": "./ets/netbirdvpnextensionability/NetbirdVpnExtensionAbility.ets",
  "type": "vpn",
  "exported": false
}
```

`ohos.permission.MANAGE_VPN` 在 SDK 权限表中属于 `system_grant/system_basic/SYSTEM`，但公开第三方 VPN API 没有 `@permission` 注解。当前普通 debug HAP 未声明此系统权限；系统 VPN 授权对话框和 Extension 生命周期均已真机成功。

## 4. 重要安全事件：create rejected 仍接管流量

### 4.1 现象

曾为验证 TUN fd，在用户显式按钮后调用 `VpnConnection.create()`。尝试过无 routes、空 DNS、应用列表限制和官方示例字段组合，Promise 均返回：

```text
code=2200003, message=System internal error
```

但系统在 Promise reject 前已经发布：

```text
VPN_CONNECTION_STATUS_CHANGED state: 1
vpn status bar status change, newState: true
```

用户随后实测京东 App 提示无法联网。这证明：

- `routes` 为空不保证其他应用流量不受影响；
- Promise reject 不代表系统没有产生部分 VPN 副作用；
- 在没有运行中 TUN 消费者时，任何 `VpnConnection.create()` 真机探针都可能导致全局断网。

### 4.2 立即处置

收到反馈后立即执行：

```powershell
$hdc = "D:\Program Files\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc shell "aa force-stop org.huangedehw.nbconnect"
```

设备确认：

```text
force stop process successfully
VPN_CONNECTION_STATUS_CHANGED state: 0
vpn status bar status change, newState: false, oldState: true
```

随后检查不到任何 nbconnect 进程，系统 VPN 接管已解除。

### 4.3 最终修复

`NetbirdVpnExtensionAbility.ets` 已恢复 `DEBUG_ENABLE_REAL_VPN_FD=false`。常规路径禁止自动 `VpnConnection.create()`；保留的显式调试方法只用于已确认的受控里程碑。`HarmonyPlatformAdapter.ets` 常规执行：

- NetworkKit 非 VPN 物理接口枚举/监听；
- Go desired snapshot revision polling；
- 地址、routes、DNS、search domain、MTU 的纯内存 `VpnConfig` 构造；
- timer、observer、Go desired config 的幂等 rollback。

最终准备路径为：

```ts
this.connection = vpnExtension.createVpnConnection(this.context);
await this.connection.protectProcessNet();
await this.platformAdapter.prepare();
// 仅构造/校验内存模型；没有 this.connection.create(config)
```

真机最终日志：

```text
VPN_EXTENSION_CREATE
VPN_PLATFORM_ADAPTER_PREPARED interfaces=1 interfaceRevision=1 desiredRevision=0
VPN_PLATFORM_ADAPTER_SELFTEST ... VPN_CREATE_DISABLED; NB_PLATFORM_BRIDGE_SELFTEST_DONE
VPN_PROCESS_PROTECTED_NO_TUN VPN_CREATE_DISABLED
```

该验证期间系统日志中没有任何 `VPN_CONNECTION_STATUS_CHANGED`。停止后：

```text
VPN_EXTENSION_DESTROY
VPN_EXTENSION_STOP_OK
```

VPN 子进程退出，UI 进程仍存活。

> 强制规则：生产自动 create 继续禁用。任何再次真实系统 VPN 测试仍需用户明确确认、应用内 destroy timer 与独立 force-stop watchdog；create reject 也必须按已产生系统副作用处理。

## 5. Harmony Go Core API

Go 入口：

```text
D:\Code\netbird\client\harmony\nbharmony.go
```

C ABI：

```go
NbCoreInit
NbCoreSetConfig
NbCoreSetPlatformState
NbCoreClearPlatformState
NbCoreSetInterfaces
NbCorePlatformSnapshot
NbCoreStartPreparation
NbCoreProvideTunFD
NbCorePlatformRollback
NbCorePlatformSelfTest
NbCoreStatus
NbCoreConnect
NbCoreShutdown
NbCoreTunSelfTest
NbCoreSelfTest
NbFreeString
```

平台状态包含：

```text
vpnExtensionReady
processProtectReady
tunFdReady
dnsReady
networkChangeReady
lastError
```

`PlatformReady` 只有全部能力就绪时才为 true。当前安全版本中 Extension/process protect、DNS bridge 和 network-change observer 已就绪，但 `tunFdReady=false`，因此 `PlatformReady=false` 且引擎不会启动。

N-API / ArkTS：

```ts
coreInit(deviceName, osVersion, configJson): string
coreSetConfig(configJson): string
coreSetPlatformState(tunFd, extension, processProtect, dns, networkChange, lastError): string
coreClearPlatformState(): string
coreSetInterfaces(interfacesJson): string
corePlatformSnapshot(): string
coreStartPreparation(stateFilePath, cacheDir, logFilePath): string
coreProvideTunFD(tunFd): string
corePlatformRollback(): string
corePlatformSelfTest(): string
coreStatus(): string
coreConnect(): string
coreShutdown(): string
coreTunSelfTest(): string
coreSelfTest(): string
```

## 6. Windows Go 构建

在 `D:\Code\netbird` 执行：

```powershell
$env:CGO_ENABLED = "1"
$env:GOOS = "linux"
$env:GOARCH = "arm64"
$env:CC = "D:\Code\nbconnect\verify\ohos-cc.bat"
$env:PATH = "D:\Code\nbconnect\verify\bin;$env:PATH"

go build -tags harmony -buildmode=c-archive `
  -o D:\Code\nbconnect\verify\libnbharmony.a `
  .\client\harmony\
```

`-tags harmony` 为强制参数。当前 archive：

```text
libnbharmony.a  113,198,882 bytes
libnbharmony.h         3,271 bytes
```

复制到 N-API 模块：

```powershell
Copy-Item D:\Code\nbconnect\verify\libnbharmony.a `
  D:\Code\nbconnect\netbird\src\main\cpp\libnbharmony.a -Force
Copy-Item D:\Code\nbconnect\verify\libnbharmony.h `
  D:\Code\nbconnect\netbird\src\main\cpp\libnbharmony.h -Force
```

依赖检查：

```text
RLIMIT_PRESENT=False
LINK_PRESENT=False
BASE_EBPF_PRESENT=True
```

基础 eBPF 包来自 Rosenpass 间接依赖；真实引擎启用前必须处理。

## 7. eBPF / Seccomp 修复

未加 Harmony tag 时，完整 Core 在 package init 阶段触发：

```text
SIGSYS(SYS_SECCOMP)
syscall 280 (bpf)
```

符号化根因：

```text
github.com/cilium/ebpf/rlimit.init.0
github.com/cilium/ebpf/rlimit.detectMemcgAccounting
github.com/cilium/ebpf/internal/sys.MapCreate
```

平台 tags：

```go
// client/internal/ebpf/instantiater_linux.go
//go:build !android && !harmony

// client/internal/ebpf/instantiater_nonlinux.go
//go:build !linux || android || harmony
```

## 8. TLS workaround

Go `c-archive` 链入 N-API `.so` 后，OHOS musl 无法加载 initial-exec TLS。CMake `POST_BUILD` 调用 `netbird/patch_tls.js`：

```text
R_AARCH64_TLS_TPREL64 -> R_AARCH64_NONE
```

规则：1 条执行 patch；0 条幂等成功；超过 1 条构建失败。最终 signed HAP 内 `libnetbird.so`：

```text
TPREL64 found=0
```

这是 workaround，不是 Go 官方修复。

## 9. Windows HAP 构建

```powershell
$env:PATH = "D:\Program Files\DevEco Studio\tools\node;$env:PATH"
$env:DEVECO_SDK_HOME = "D:\Program Files\DevEco Studio\sdk"

& "D:\Program Files\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  clean assembleHap --mode module `
  -p product=default -p buildMode=debug --no-daemon
```

最终安全版本：

```text
BUILD SUCCESSFUL
D:\Code\nbconnect\netbird\build\default\outputs\default\netbird-default-signed.hap
```

HAP 的 `module.json` 已确认包含 `NetbirdVpnExtensionAbility type=vpn`。

## 10. 真机回归

设备：`4YM0225529009428`。

最终状态 IPC 安全版本：

- UI PID：`15459`；
- VPN 进程 PID：`15914`；
- 两个 PID 不同，分别加载自己的 N-API/Go Core；
- `VPN_PROCESS_PROTECTED_NO_TUN`；
- `ready` 从 VPN PID 发布并由 UI PID 接收；
- 自动状态请求 `1788484246618-573008` 与手动请求 `1788484276326-510901` 均由 VPN 进程以相同 `requestId` 返回；
- 响应包含 `deviceName=nbconnect-vpn`、`clientStatus=Idle`、`tunFdReady=false`，证明不是 UI 本地单例；
- 启动、两次状态请求和停止期间均无 `VPN_CONNECTION_STATUS_CHANGED` 或系统 VPN 状态栏 connected 事件；
- `stopVpnExtensionAbility()` 返回 `VPN_EXTENSION_STOP_OK`，VPN PID `15914` 随后退出，UI PID `15459` 保持存活；
- `onDestroy` 记录 `VPN_IPC_STATUS_SENT kind=stopped`，但 UI 未在子进程被系统终止前收到，因此它只作为尽力通知，不作为可靠停止确认。

fd TUN + Harmony interface factory 安全版本（仍未建立系统 VPN）：

- UI PID：`3650`；VPN Extension 最新回归 PID：`6904`；
- signed HAP：`33,699,882 bytes`；包内 `libnetbird.so`：`31,836,456 bytes`；`TPREL64 found=false`；
- `NbCoreTunSelfTest` 在 UI 进程创建本地 `AF_UNIX SOCK_DGRAM socketpair`，不访问系统 VPN；
- 真机通过 raw packet read/write、headroom offset、dup fd 所有权、close 取消阻塞 read 和完整 Harmony `NewWGIFace/Create/Close` factory；
- 首次 factory 自检使用 `stdnet.NewNet` 时被 sandbox 拒绝 netlink route 查询；测试夹具已改为纯内存 Pion `vnet`，最终不访问系统 route/netlink；
- 关键结果：
  ```text
  FDTUN_SELFTEST {"ok":true,"code":0,..."Harmony interface factory OK; NB_FDTUN_SELFTEST_DONE"}
  ```
- Linux factory/device/Destroy build tags 已排除 `harmony`；Harmony device 不调用 `CreateTUN`、assignAddr、netlink LinkDel 或 UAPI listener；
- factory 对 nil/0/negative fd fail closed；编译期 helper 只在 `FileDescriptor>0` 时注入，普通零值 `Run()` 不会把 stdin fd0 当作 TUN；
- 最终 HAP 手动请求 `1788493769414-827773` 在 UI/VPN 两个 PID 间完整匹配，响应仍为 `deviceName=nbconnect-vpn`、`tunFdReady=false`；
- 停止后 VPN PID 为空，UI PID `3650` 留存；
- `coreConnect()` 仍返回 `-100`，`NB_SELFTEST_DONE` 仍通过；整个自检、Extension 启停和 IPC 回归期间无 `VPN_CONNECTION_STATUS_CHANGED`。

本地 Windows 测试：

```text
TestDeviceReadPreservesPacketAndOffset PASS
TestDeviceWritePreservesPacketsAndOffset PASS
TestDeviceCloseCancelsReadAndIsIdempotent PASS
TestDeviceEventsAndMetadata PASS
TestDeviceRejectsInvalidArguments PASS
```

`go test -race` 因 Windows 环境没有 `gcc` 无法构建 race runtime；普通测试和 Harmony 交叉编译均成功。Harmony `iface` 与 `internal` 定向测试二进制也已交叉编译；设备 SELinux 禁止从 `/data/local/tmp` 执行推送二进制，因此运行期覆盖由签名 HAP 内的 `NbCoreTunSelfTest` 完成。

关键请求/响应日志：

```text
VPN_IPC_STATUS_SUBSCRIBED
VPN_IPC_COMMAND_SUBSCRIBED
VPN_IPC_STATUS_SENT kind=ready request=ready-1788484245736
VPN_IPC_STATUS_RECEIVED kind=ready request=ready-1788484245736
VPN_IPC_STATUS_REQUEST_SENT request=1788484246618-573008
VPN_IPC_COMMAND_RECEIVED kind=status-request request=1788484246618-573008
VPN_IPC_STATUS_SENT kind=status-response request=1788484246618-573008
VPN_IPC_STATUS_RECEIVED kind=status-response request=1788484246618-573008
```


### 10.1 RunOnHarmony 与平台服务隔离（本轮）

Go Core 已新增显式 `MobilePlatformHarmony` 和 `ConnectClient.RunOnHarmony`。入口必须收到 `fd>0`、`ExternalIFaceDiscover`、network-change listener、`MobileDNSManager`、app-private state file 与 cache 路径；普通 `Run()` 在 `-tags harmony` 构建中直接 fail closed。Harmony 不再因 `GOOS=linux` 回退到 desktop service/state path，并跳过 installer cleanup。

Engine 平台分派已完成：

- `newStdNet` 只使用宿主 `ExternalIFaceDiscover`，不回退 Pion/Linux netlink discovery；
- DNS 使用 memory service + `mobileHostManager`，序列化 `HostDNSConfig` 后交给宿主；Linux resolv.conf、systemd、DBus 和 unclean-shutdown repair 从 Harmony 排除；
- route `SysOps` 只维护 prefix 集合并通知宿主，不调用 Linux route table、sysctl 或 `ToInterface()`；
- firewall 强制 userspace filter，并使用 no-op firewalld 与移动 conntrack 配额；
- network monitor、WireGuard interface monitor、Linux netflow conntrack/sysctl、kernel module 探测、UAPI cleanup/fwmask 和 Linux debug route/firewall 收集均从 Harmony 路径排除。

验证结果：Windows 定向测试通过；Harmony `internal`、DNS、route/systemops、configurer 测试包交叉编译成功；完整 `c-archive` 为 `92,802,990 bytes`，header `2,536 bytes`；clean signed HAP 为 `33,210,954 bytes`，包内 `libnetbird.so` 为 `31,354,696 bytes`，`TPREL64_FOUND=False`。

最终签名 HAP 真机结果：UI PID `40692`；无系统 VPN 自检返回 `Harmony interface factory OK; Harmony platform policy OK; NB_FDTUN_SELFTEST_DONE`，VPN 子进程为空；`coreConnect` 仍为 `code=-100`；`NB_SELFTEST_DONE` 通过。随后安全 Extension PID `42492` 完成 `VPN_PROCESS_PROTECTED_NO_TUN`，手动请求 `1788502252993-804527` 在 UI/VPN 两进程四阶段 ID 一致，响应为 `deviceName=nbconnect-vpn`、`clientStatus=Idle`、`tunFdReady=false`。停止后 `VPN_EXTENSION_STOP_OK`、`VPN_EXTENSION_DESTROY`，VPN PID 为空、UI PID 保持 `40692`；整个流程未记录 `VPN_CONNECTION_STATUS_CHANGED`。

本轮之后 ArkTS IFaceDiscover/DNS/route `VpnConfig` 内存消费者和统一 rollback 已实现并完成下一节真机验证；`VpnConnection.create()` 与 `NbCoreConnect -> RunOnHarmony` 仍保持禁用。

- `coreConnect()`：

```json
{"ok":false,"code":-100,"message":"HarmonyOS VPN engine adapter is not ready"}
```

- WireGuard/runtime：

```text
GO_RUNTIME_OK wg pubkey len=32; goroutines sum=619940000; wg device created OK; NB_SELFTEST_DONE
```

- clean Hvigor 构建成功；无 TypeError、TLS error、SIGSYS、SIGSEGV 或 panic。

### 10.2 ArkTS ↔ Go 平台配置桥与 rollback（本轮）

新增 Go 文件：

```text
D:\Code\netbird\client\harmony\platform_adapter.go
D:\Code\netbird\client\harmony\platform_adapter_test.go
```

`harmonyPlatformAdapter` 由 `harmonyCore` 持有，并同时实现 `ExternalIFaceDiscover`、`NetworkChangeListener` 和 `MobileDNSManager`。ArkTS 通过 NetworkKit 仅收集带 `NET_CAPABILITY_NOT_VPN` 的网络，合并同名接口、排序/去重 prefix 后送入 Go。接口快照使用独立 `interfaceRevision`；Go 产生的 tunnel address、route、DNS、search domain 和 MTU 使用 `revision`。Harmony `wgInterfaceCreate` 通过可选 `SetMTU(int)` capability 把实际 engine MTU 送入 adapter，不改变 Android/iOS listener ABI。ArkTS 每 250ms 拉取 desired snapshot，在自己的线程只构造内存 `VpnConfig`，不调用系统 create。

`HarmonyPlatformAdapter.ets` 的 rollback 状态机执行：

1. 停止 refresh/poll timer；
2. unregister `NetConnection` observer；
3. 调用 `corePlatformRollback()` 幂等清 Go desired config；
4. 清内存 `VpnConfig`；
5. 只有未来 `vpnCreated=true` 时才调用 `destroy()`；当前该标志固定 false。

首次真机发现 `NetConnection.register` 成功回调传入 `undefined`，直接访问 `error.code` 导致 `TypeError` 和 VPN 子进程退出。现已兼容 `undefined/null`，重新 clean 构建、安装后通过。

该平台桥阶段产物（后续 late-fd 入口使最终 archive/HAP 增大）：

```text
libnbharmony.a                 92,846,212 bytes
libnbharmony.h                      2,721 bytes
netbird-default-signed.hap     33,274,366 bytes
libnetbird.so                  31,387,368 bytes
TPREL64_FOUND=False
```

设备 `4YM0225529009428` 最终证据：

- UI PID `6571`，VPN PID `7343`；
- `VPN_PLATFORM_ADAPTER_PREPARED interfaces=1 interfaceRevision=1 desiredRevision=0`；
- `VPN_CREATE_DISABLED; NB_PLATFORM_BRIDGE_SELFTEST_DONE`；
- ready/status 显示 `tunFdReady=false`、`dnsReady=true`、`networkChangeReady=true`、`engineRunning=false`；
- 联合 signed-HAP 自检报告 `NB_PLATFORM_ADAPTER_SELFTEST_DONE; NB_FDTUN_SELFTEST_DONE`；
- `coreConnect()` 仍返回 `code=-100`、`engineRunning=false`；
- 停止触发 `VPN_EXTENSION_DESTROY` 和 observer/command unsubscribe，VPN PID 退出，仅 UI PID 保留；
- 应用日志原始 interface/address/route/DNS 匹配数为 0；
- `VPN_CONNECTION_STATUS_CHANGED` 匹配数为 0。

Windows `go test ./client/harmony/` 通过，含接口验证、排序去重、DNS/route/address/MTU snapshot、revision、并发访问和幂等 rollback。`go test -race` 因当前 Windows Go 环境 `CGO_ENABLED=0` 无法启动，普通并发测试和 OHOS 交叉编译均成功。

### 10.3 context-aware late-fd 两阶段准备（本轮）

新增 `device.TunFDProvider`：

```go
type TunFDProvider interface {
    WaitTunFD(ctx context.Context) (int, error)
}
```

`ConnectClient.RunOnHarmonyWithFDProvider` 保留原 static-fd `RunOnHarmony` 兼容路径。Harmony `NewWGIFace` 接受正 static fd 或 provider；`TunDevice.Create` 才调用 `WaitTunFD`，因此 management login、EngineConfig、memory DNS server 和 route manager model 可先准备。Engine 在进入 wait 前经 notifier 发布 overlay IPv4/IPv6、实际 MTU 和内存 DNS IP，adapter 自动加入 masked overlay base route。

adapter 维护 `preparationGeneration` 与状态：

```text
idle -> awaiting-fd -> fd-provided -> fd-received -> fd-consumed
                       \-> cancelled / rolled-back
```

provider 返回 `fd<=0`、重复 wait、非 awaiting 状态 provide、config 未 ready provide 均 fail closed。`coreProvideTunFD` 返回仅表示排队；channel receive 后状态为 `fd-received`，只有 `fdtun.NewFromFD` 成功复制平台 fd 并回调 `TunFDConsumed` 后才进入 `fd-consumed`。Engine context cancel、ArkTS timeout 和 platform rollback 都会解除 wait；rollback 在 client/notifier 退出后再次清 desired config，并处理 provide/consume 竞态。

新增 C ABI/N-API：

```text
NbCoreStartPreparation / coreStartPreparation
NbCoreProvideTunFD / coreProvideTunFD
```

`startCorePreparation` 只在显式调用时异步登录并等待 `awaiting-fd + configReady`；超时走统一 rollback。普通 status 只公开 `preparationRunning/state/generation`，不公开 address/route/DNS。常规 Extension 启动不调用 preparation，更不调用 `VpnConnection.create()`。

### 10.4 首个 Management NetworkMap prefetch（本轮）

Harmony `TunFDProvider` 路径现在在 `routeManager` 与 memory DNS model 初始化后、`wgInterfaceCreate` 之前启动**唯一一条** `mgmClient.Sync`。首个含 NetworkMap 的响应按以下顺序处理：

1. 共用 `decodeNetworkMap` 解码 legacy `NetworkMap` 或 components envelope；
2. `PrepareRouteRanges` 只分类/选择 static client routes，排除本机 server route、dynamic domain route 和 `DisableClientRoutes`，不创建 route handler、不改系统路由；
3. `HostDNSConfigFromConfig` 使用 memory DNS IP 投影 DNS/search domains，经既有 mobile notifier 进入 revisioned desired snapshot；
4. 首包之前的 config-only 响应和首个 NetworkMap 均保留；由于 `Engine.Start` 持有 `syncMsgMux`，stream callback 在投影完成后阻塞；
5. ArkTS 只有在上述投影完成后才可能观察到 `awaiting-fd`；接口获得 fd 并成功 Up 后，缓存响应按原顺序交给 `handleSync`，之后同一 stream 继续处理增量消息。

该方案不建立第二条临时 Sync，因此没有双流 serial/peer 竞态。30 秒未收到首个 NetworkMap、stream close/error、Engine context cancel 或 rollback 都会 fail closed 并停止本轮 Engine；不会进入 fd wait。首包 prefetch 不应用 peers、firewall、ACL 或 route handlers。

测试覆盖：routes/DNS 无副作用投影、config-only + 首包缓存、`syncMsgMux` 延迟回放、timeout cancel、static route 去重、dynamic/server route 排除及 `DisableClientRoutes`。Windows 完整包测试通过；Harmony arm64 交叉测试产物为 `internal_initialmap.test 47,053,357 bytes` 与 `routemanager_initialmap.test 42,352,325 bytes`。signed-HAP synthetic NetworkMap 自检报告 `Harmony initial NetworkMap preparation OK` 与 `NB_INITIAL_MAP_PREFETCH_SELFTEST_DONE`。普通 Extension 仍不自动运行真实 management preparation，避免把凭据放入 CommonEvent 或日志。

### 10.5 运行期 NetworkMap revision 重配协调器（本轮）

首包之后 route/DNS desired config 变化现在使用独立于普通 snapshot `revision` 的 `configRevision`：首次 `fd-consumed` 记录 `appliedConfigRevision`；后续变化经过 250ms quiet-period debounce，同一窗口和 pending 阶段的变化合并到一个 generation/target。`beginReconfiguration(expectedGeneration, expectedTarget)` 会拒绝 stale generation、target 和未结束 debounce。

fd 生命周期新增可选兼容接口：

```go
type TunFDLeaseProvider interface {
    WaitTunFDLease(ctx context.Context) (fd int, lease uint64, err error)
}
type TunFDLeaseLifecycleNotifier interface {
    TunFDConsumedForLease(lease uint64)
    TunFDReleasedForLease(lease uint64)
}
```

旧 static-fd/provider 行为保留。Harmony `TunDevice` 只在 `fdtun.NewFromFD` 成功 dup 后发送 matching consumed；`Close` 等 wireguard/fdtun duplicated transport 关闭完成后只发送一次 matching released。stale lease callback 不改变新 generation。

Core 协调分两阶段：

1. `NbCoreBeginReconfiguration(generation,target)` 先失效旧 preparation ownership，再异步 `ConnectClient.Stop()`；
2. matching old lease release 后进入 `rebuilding-client`，使用 `ConfigToJSON/ConfigFromJSON` 在内存克隆配置和凭据；fresh client 赋值后才发布 `old-fd-released`，避免宿主过早 restart；
3. 宿主已在此窗口通过 `VpnReconfigurationCoordinator` 编排 destroy/recreate：release lease 校验后销毁旧 VPN，restart 后创建新 VPN、versioned provide 并等待 matching consumed；`DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION=false`，当前不自动执行；
4. `NbCoreRestartPreparation` 启动新 management/Engine preparation；
5. `NbCoreProvideTunFDForGeneration` 同时校验 preparation generation、reconfiguration generation 和 config revision；只有 matching `fd-consumed` 才更新 applied revision；provide 与 consume 之间的新变化会再调度下一 generation。

任一步错误进入 `failed`/rollback，旧 preparation goroutine 必须先核对 `preparationID` 和 client identity，不能清除新 generation。ordinary status 只增加非敏感 revision/generation/state，不包含原始 address/route/DNS 或凭据。

单测覆盖 debounce/coalescing、stale generation/target/preparation/config/lease、release/rebuild 竞态与 provide 后配置再次变化。Go 四包测试、Harmony arm64 c-archive、N-API/ArkTS、签名 HAP 均通过。设备 `4YM0225529009428` 的 signed-HAP 返回 `ok=true`，同时报告 matching consumed/released lease、`NB_INITIAL_MAP_PREFETCH_SELFTEST_DONE`、`NB_RECONFIGURATION_SELFTEST_DONE`、`NB_LATE_FD_SELFTEST_DONE`、`NB_PLATFORM_ADAPTER_SELFTEST_DONE` 和 `NB_FDTUN_SELFTEST_DONE`。安全 Extension 的 UI/VPN PID 为 `4703/4784`，日志包含 `VPN_PROCESS_PROTECTED_NO_TUN`、`VPN_CREATE_DISABLED`；停止后 `VPN_EXTENSION_STOP_OK`、`VPN_EXTENSION_DESTROY`，VPN PID 退出而 UI PID 保留。最终扫描：`RAW_PLATFORM_DETAIL_MATCHES=0`、`VPN_CONNECTION_STATUS_CHANGED_MATCHES=0`、`FAILURE_MARKER_MATCHES=0`。

真实 fd 的 raw packet/共享 `O_NONBLOCK`、首次系统 rollback 和宿主 destroy/recreate 协调器均已完成；fake lifecycle 覆盖 release/restart/create/provide/consume 的成功顺序与失败rollback。受控真实事务进一步验证了初始 fd、`old-fd-released`、系统 destroy、新 VPN create、versioned provide、matching consumed 与新 fd raw packet；connected/disconnected 各 2、自动 rollback 1、failure 0、最终进程数 0。真实测试发现并修复 target 清零的两层终态判断及新 fd stats reset 时序。剩余限制是前后台、网络切换、进程死亡和压力场景。

最终验证：

```text
libnbharmony.a             113,198,882 bytes
libnbharmony.h                   3,271 bytes
signed HAP                  40,007,600 bytes
libnetbird.so               38,051,272 bytes
TPREL64_FOUND=False
```

设备 `4YM0225529009428` 的上一无 VPN 里程碑证据：UI/VPN PID `17025/18401`。provider-backed 联合 FDTUN 自检报告 `Harmony initial NetworkMap preparation OK`、`NB_INITIAL_MAP_PREFETCH_SELFTEST_DONE`、`Harmony late-fd duplication acknowledgement OK`、`NB_LATE_FD_SELFTEST_DONE`、`NB_PLATFORM_ADAPTER_SELFTEST_DONE` 与 `NB_FDTUN_SELFTEST_DONE`；系统 VPN 状态变化为 0。安全 Extension 仅执行 `protectProcessNet` 和平台 adapter preparation，保留 `VPN_CREATE_DISABLED`；停止后报告 `VPN_EXTENSION_STOP_OK`、`VPN_EXTENSION_DESTROY`，VPN PID 退出，仅 UI PID 留存。最终 `RAW_PLATFORM_DETAIL_MATCHES=0`、`VPN_CONNECTION_STATUS_CHANGED_MATCHES=0`。真实 management stream prefetch 由 Go 单流测试覆盖；本轮真机采用 signed-HAP synthetic NetworkMap projection，未通过 IPC 传输凭据，也未创建系统 VPN。

### 10.6 Components NetworkMap 与 SQLite Router workaround

Harmony 私有配置的新建与恢复都强制 `SyncMessageVersion=HighestSyncMessageVersion`。combined Management `0.78.0` 必须在已有的 `server:` 节点启用：

```yaml
server:
  supportedSyncMessageVersions: 1
```

`0.78.0` SQLite Router 查询使用 `from network_routers, json_each(peer_groups)`。direct-peer Router 的 `peer_groups=[]` 使 `json_each([])` 返回零行，Router 因交叉连接从 NetworkMap 消失；PostgreSQL 路径不受该问题影响。服务端正式修复应从 `network_routers` 保留左表，例如：

```sql
from network_routers
left join json_each(network_routers.peer_groups) on true
left join group_peers
  on group_peers.account_id=?
  and group_peers.group_id=json_each.value
where network_routers.account_id=?
```

当前已将目标 Router 改为绑定专用单-peer网关组 `nbconnect-router-workaround`，并保留原 enabled/metric/masquerade。该组是生产 workaround；在 SQLite SQL 正式修复并升级前不得删除，也不得恢复 direct-peer 绑定。

### 10.7 无 Windows/HDC 中继直连与稳定性（2026-09-09）

Harmony archive 使用 `GOOS=linux`，原 `client/grpc/dialer_generic.go` 因而误入 Linux `user.Current()`/root 自定义 dialer。配置 Dial override 时，Management/Signal 后追加的标准 `net.Dialer` 会覆盖该分支，所以旧中继链路可用；无 override 时 gRPC 则持续到 `dial context deadline exceeded`。修复方式是增加 build-tag 平台开关：Harmony 强制使用标准 `net.Dialer`，其余平台保持原行为；另在私有认证中增加不输出地址的 TCP 前置探测，区分 socket 不可达与 gRPC 建连失败。

最终真机在 `relay=0`、`HDC rport=0`、Dial override 为空时完成：

- Management private auth、Signal、components NetworkMap 全部 ready；
- 显式 Connect matching fd-consumed，NetworkMap `syncVersion=1, decodedRoutes=3`；
- 前台→后台 60 秒→重新前台，双进程持续存活，handshake=2、Tx/Rx active、HTTP 301；
- 活动 VPN 下 Wi-Fi→蜂窝→Wi-Fi，两次切换均无系统 VPN down/failure，控制面、握手和 HTTP 自动恢复；
- 30 分钟 soak 共 7 点、1815 秒：每点 processes=2，map/peer/TUN 全部通过，failure/down/thread-block 全为 0；总 RSS `264264,264236,264312,263884,264192,264120,250144 KB`，线程 `60→57`，无持续增长；结束后 HTTP 仍返回 301；
- 活动 VPN 中 force-stop 后 12 秒内进程=0、系统 VPN state=0；随后无中继重新认证、Connect、HTTP 成功，并通过正常 Disconnect 再次回到 state=0。

UI 自动化中曾出现息屏拒绝触摸、HTTP 输入残留和 hilog 环形缓冲计数假阴性；最终 soak 使用逐窗口 hilog、显式 wakeup/前台化和权威状态采样，未将这些自动化问题计入 VPN failure。

### 10.8 公网 P2P / Direct 数据面（2026-09-09）

routing peer 最初持续显示 `Connected/Relayed`，其 WireGuard runtime endpoint 为 loopback，证明流量来自 NetBird Relay 本地代理而非 Harmony 公网 UDP。服务器主机侧已确认 UDP 51820 IPv4/IPv6 wildcard 监听、forwarding 开启、iptables INPUT ACCEPT、UFW/firewalld 未启用且 nft input hook 为 accept。

真机应用内分层 UDP 探测得到：

- UI 进程向动态内存目标发送 24 个固定 marker，服务器物理 `eth0` 命中 15 个，证明云安全组、公网 NAT 和设备默认 UDP 出口并非完全阻断；
- VPN Extension 在只调用 `protectProcessNet()` 时同样报告发送 24 个，但 `eth0` marker 命中 0；
- 临时使用进程级 `connection.setAppNet()` 后 Extension marker 命中 15 个，但它会扩大到 Management/Signal 等所有 socket，不作为生产方案；
- 最终方案使用 Harmony NDK `OH_NetConn_GetDefaultNet` + `OH_NetConn_BindSocket`，只绑定 WireGuard `StdNetBind` 创建的 UDP socket；gRPC/TCP 和其他 listener 保持原行为，`protectProcessNet()` 继续保留；
- Harmony archive 仍以 `GOOS=linux -tags harmony` 构建，因此 ICE 原 `!android` 分支会误用系统接口枚举。新增 `stdnet_harmony.go` 强制使用已注入的 `ExternalIFaceDiscover`，并以 build-tag 回归测试锁定。

最终真机脱敏计数：

```text
VPN_NATIVE_UDP_BIND attempts>0 succeeded>0 failed=0
VPN_ICE_DIAGNOSTICS agents=3 offers=2 gathers=2 gatherFailed=0 localCandidates=4 remoteCandidates=3
HARMONY_STATUS=Connected
HARMONY_CONNECTION_TYPE=P2P
ICE local/remote type present
ICE local/remote endpoint present
Tx/Rx active
```

当前 NetBird JSON 使用 `P2P` 表示 Direct 路径；`relayAddress` 仍可作为可用 fallback 元数据存在，不能据此把当前 active path 判为 Relay。临时 UI/Extension UDP marker 代码和服务器 pcap 已删除；保留的计数诊断不包含 fd、netId、地址、candidate 内容、route、DNS、SNI 或 packet。

## 11. 下一阶段设计

### 11.1 跨进程控制面

状态与控制面已完成 IPC v2：UI 和 VPN 进程使用同包定向 CommonEvent，权威 Core 位于 `:vpn` 进程，所有响应带原 requestId。

已实现：

```text
status-request/status-response
control-request: initialize/configure/connect/disconnect/shutdown
control-response: command/ok/code/message/duplicate/lifecycleState/status
```

安全语义：control payload 只接受一个 `command` 字段；旧 version、未知命令和附加 credential/config 字段 fail closed。UI 维护 pending Map、5 秒 timeout 和 command 匹配校验；Extension 使用串行 Promise 队列与 64 项响应缓存，相同 requestId/command 返回 `duplicate=true`，不同命令冲突返回 `-409`。显式 coordinator 管理 `ready → connecting → connected → disconnecting → disconnected`，重复 Connect/Disconnect 无副作用，失败统一 rollback。宿主 Connect 已接入 prepared-config create/versioned provide/consumed，Disconnect 接入 adapter rollback；生产策略只接受同包显式用户命令，Extension 启动不自动 create。底层 `coreConnect()` 仍保留 `-100` 边界；`shutdown` 先 rollback/Core shutdown，确认后 UI 才调用 `stopVpnExtensionAbility()`。

历史 IPC v2 边界证据：initialize `0`、同 requestId 幂等重放、configure 未 ready `-409`、旧 connect/Core 边界 `-100`、shutdown `0` 后进程退出，系统 VPN 状态事件为 0。当前显式状态机 signed HAP 报告 protocol/lifecycle self-test 通过；一次性 gate 真机进一步验证 Connect `code=0, changed=true, state=connected`，不同 requestId 重复 Connect 为 `changed=false` 且 connected event 仍为 1；Disconnect `code=0, changed=true, state=disconnected` 并产生唯一 disconnected event。重复 Disconnect 在独立无 create prepared 流程得到 `changed=true` 后 `changed=false`、response=2、系统 VPN event=0。默认 gate 随后恢复 false。

### 11.2 fd-backed TUN adapter

已新增：

```text
D:\Code\netbird\client\harmony\fdtun\device.go
D:\Code\netbird\client\harmony\fdtun\fd_harmony.go
D:\Code\netbird\client\harmony\fdtun\device_test.go
D:\Code\netbird\client\harmony\tun_selftest_harmony.go
D:\Code\netbird\client\iface\iface_new_harmony.go
D:\Code\netbird\client\iface\iface_destroy_harmony.go
D:\Code\netbird\client\iface\device\device_harmony.go
D:\Code\netbird\client\internal\mobile_iface_args_harmony.go
```

adapter 直接实现 wireguard-go `tun.Device`：

- `File/Read/Write/MTU/Name/Events/Close/BatchSize`；
- `BatchSize=1`，每次 fd read/write 对应一个 raw IP packet；
- 支持 WireGuard headroom offset，并拒绝非法 buffer/offset；
- `EventUp` / `EventDown`；
- `sync.Once` 幂等关闭；关闭时取消 Go 侧阻塞 read；
- 平台原 fd 由 `VpnConnection` 持有，Go 使用 `unix.Dup` 的副本且只关闭副本。

`unix.SetNonblock(dupFD, true)` 是 Go netpoll 在 `Close()` 时取消阻塞 I/O 的前提。dup 与原 fd 共享 open-file description；受控真实 fd 已在 `SetNonblock` 后用 `F_GETFL` 验证 `O_NONBLOCK`，并在正常 `VpnConnection.destroy()` 后恢复系统 VPN。

Windows 使用 `net.Pipe` 执行 5 项生命周期测试；Harmony 真机使用 `SOCK_DGRAM socketpair` 验证 packet 边界、所有权和取消路径。该自检不调用 `VpnConnection.create()`，不建立 TUN、路由或 DNS。

Harmony interface 创建边界已完成：

1. `iface_new_linux.go`、`device_usp_unix.go`、`iface_destroy_linux.go` 均以 `!harmony` 排除；
2. Harmony factory 只接受 `fd>0` 或 context-aware provider，不会探测 kernel WireGuard 或 `/dev/net/tun`；
3. Harmony device 在 `Create` 阶段解析 static fd/provider 并使用 `fdtun.NewFromFD`，不 assignAddr、不创建 UAPI listener，Destroy 交还 `VpnConnection` 生命周期；
4. `engine.newWgIface` 通过编译期 `configureMobileIFaceArgs` 注入 fd/provider，而不是假装 `runtime.GOOS=ios`；
5. Android/iOS 原有注入行为保留；Harmony 零值 dependency 不产生 `MobileArgs`，防止 stdin fd0 被误用；
6. 真机 socketpair 已完整执行 `NewWGIFace`、`Create`、设备检查、`Close` 和原 fd 所有权验证。

Go 层已完成的接线：

1. 安全 `ConnectClient.RunOnHarmony` 入口与显式 `MobilePlatformHarmony`；
2. mobile DNS host configurator、network/tunnel notifier 和 route prefix notifier；
3. route/firewall/network monitor/WireGuard monitor 及相关 Linux sysctl/netlink/UAPI 路径隔离；
4. app-private state/cache 路径选择，普通 `Run` 在 Harmony fail closed。

已完成的宿主接线：

1. NetworkKit 非 VPN `ExternalIFaceDiscover` 输入；
2. DNS/route/address/MTU revision snapshot 与纯内存 `VpnConfig` 消费者；
3. C ABI/N-API polling bridge 与无原始网络信息的普通状态边界；
4. timer、observer、Go desired config 和未来 `destroy()` gate 的统一幂等 rollback；
5. context-aware late-fd provider、异步 preparation C ABI/N-API、prepared snapshot polling 与 timeout rollback；
6. generation-safe `begin/restart/versioned-provide` C ABI、N-API 与 ArkTS 显式方法；
7. `VpnReconfigurationCoordinator` 串联 old release、旧 VPN destroy、restart、新 create、versioned provide 和 matching consumed；create timeout/reject 立即 destroy，晚到 resolve 再 destroy，outer rollback保留 attempt ownership；automatic gate 默认 false。

受控真实数据面已完成；尚未完成的生产接线：

1. 已验证真实 fd：create 后立即 generation/config-revision-aware provide；首 nibble 仅允许 IPv4/IPv6，read=49、invalid=0；duplicated fd 的 `O_NONBLOCK` 经 `F_GETFL` 确认；
2. 初始 NetworkMap 已在 create 前完成：唯一 management Sync 先投影 selected static routes/DNS domains，再在 interface Up 后回放原响应；
3. 运行期 Core 与宿主协调器代码已完成，并通过 fake lifecycle 与受控真实 active VPN 重配：`old-fd-released` 后系统 destroy/recreate、restart、versioned provide、matching `fd-consumed` 和第二次 raw packet 全部通过。Core 成功 consume 后清零 target revision；ArkTS 先接受 `fd-consumed + applied revision + stable`，协调器验证 target 已清零并在结果保留原请求 target。stats 窗口在旧 VPN 销毁后、新 VPN 创建前重置，确保 nonblocking 与 packet 证据只来自新 fd；
4. IPC v2 已开放受控 initialize/configure/connect/disconnect/shutdown；显式连接 coordinator、宿主 create/provide/consume 与 rollback 已通过 fake lifecycle 和真实 Connect/Disconnect。生产策略已启用为同包用户命令专用，启动不自动 create；底层 `NbCoreConnect` 保持 `-100`。脱敏 peer runtime 摘要在延迟回放后显示 known=7、connected=2，但尚无握手/流量；凭据文档没有测试目标，内部 peer 地址又不进入日志/CommonEvent，因此端到端测试等待可达 peer 地址/主机名或 app-private 诊断通道。后续还需验证 stop、进程死亡、前后台、网络切换及长期压力。

受控真机证据（默认 gate 随后恢复为 `false`）：

```text
VPN_PRIVATE_AUTH_READY state=authenticated
VPN_MANAGEMENT_NETWORK_MAP_READY configRevision=5 preparationGeneration=1
VPN_CONNECTION_STATUS_CHANGED state: 1
VPN_REAL_FD_CONSUMED generation=1 configRevision=5 nonblocking=true
VPN_DEBUG_FD_TRAFFIC_PROBE_SENT
VPN_REAL_FD_RAW_PACKET_OK read=49 write=0 invalid=0
VPN_REAL_FD_ACTIVE_DEBUG
VPN_CONNECTION_STATUS_CHANGED state: 0
VPN_DEBUG_AUTO_ROLLBACK_DONE
```

connected/disconnected event 各 1；15 秒应用内 rollback 成功，25 秒 watchdog 已触发，最终 UI 与 `:vpn` 进程数均为 0。测试不记录 fd 数值、packet 内容、地址、路由、DNS、SNI 或凭据。

### 11.3 安全认证与真实 Management + Signal prefetch

当前真机链路已完成以下闭环：

1. UI 使用 password TextInput；native writer 将 setup key、Management URL 和 runtime transport 写入 application-context `filesDir` 的 `0600` 一次性文件；
2. VPN 进程先调用 `protectProcessNet()`，随后读取 import 并在任何网络操作前删除；ArkTS/CommonEvent/hilog/普通 status 均不携带 setup key；
3. 成功注册后只持久化 NetBird 生成的 config/private keys；无 credential 时直接恢复。用户显式再次导入 setup key 时用原私钥执行 `Auth.Login`，仅在服务端要求时重新登记同一公钥；
4. `module.json5` 必须声明 `ohos.permission.INTERNET`。只声明 `GET_NETWORK_INFO` 会导致 Go TCP dial 全部失败；
5. HDC reverse 的 loopback listener 对 shell 可见但对 VPN app sandbox 不可达。当前 Windows-only 调试使用电脑加入设备同一 WLAN，并运行受限 SNI relay：只接受设备源 IP和允许域后缀；Management authority 映射到凭据指定固定 socket target，Signal 按自身 SNI:443 转发；不记录地址、SNI 或内容；
6. relay 必须正确执行 TCP half-close 并等待双向 copy 完成，不能在 gRPC request 方向 EOF 后立刻关闭 response 方向；
7. `shared/signal/client.ContextWithDialAddress` 与 Management override 使用同一 runtime socket destination，但各自保留原 gRPC target/TLS authority；`ManagementPrefetchOnly` 和 Signal mock branch 已删除，真实 Signal 在 Engine/Sync 前连接。

真机证据：

```text
VPN_PRIVATE_AUTH_READY state=authenticated
VPN_MANAGEMENT_NETWORK_MAP_READY auth=private configRevision=5 preparationGeneration=1
authentication.state=network-map-ready
preparationState=awaiting-fd
managementConnected=true
signalConnected=true
REAL_SIGNAL_CONFIG_READY=true
VPN_PROCESS_PROTECTED_NO_TUN VPN_CREATE_DISABLED
SNI_RELAY_BYTES_DEVICE_TO_TARGET=3025 / 2872 / 1687
SNI_RELAY_BYTES_TARGET_TO_DEVICE=6880 / 12121 / 5744
HILOG_SETUP_KEY_MATCHES=0
SNI_RELAY_SETUP_KEY_MATCHES=0
VPN_CONNECTION_STATUS_CHANGED_MATCHES=0
VPN_CREATE_CALL_MATCHES=0
APP_PROCESS_COUNT=0
```

调试 UI 在前台窗口启用 `setWindowKeepScreenOn(true)`，真机 marker 为 `DEBUG_KEEP_SCREEN_ON_ENABLED`；它只阻止该窗口前台期间自动熄屏，发布版应关闭 `DEBUG_KEEP_SCREEN_ON`。

### 11.4 真实 VPN 测试门槛

平台 bridge、真实 Management + Signal、认证/NetworkMap、late-fd、初始/后续 NetworkMap、真实 raw fd/`O_NONBLOCK`/rollback、IPC v2、运行期重配、正式显式 Connect/Disconnect 和 production user-command-only enable policy 均已完成。生产 HAP 启动只 preparation，自动 VPN event=0；显式 Connect matching consumed，Disconnect 后 connected/disconnected 各 1、failure=0、watchdog 后进程=0。普通状态现包含严格脱敏 peer runtime 摘要；延迟 NetworkMap 回放后为 `known=7, connected=2, withHandshake=0, Tx/Rx inactive`。下一关键门槛是获得一个可达 peer 地址/主机名（或实现不经日志/CommonEvent的 app-private 诊断通道），从 UI 进程产生真实业务流量并验证 handshake、Tx/Rx；之后继续前后台、网络切换、进程死亡和压力测试。两个 debug gate 保持 false，底层 `coreConnect=-100`。

`docs/connectAccount.md` 仅由本地自动化动态读取；值不得回显、写入 hilog、CommonEvent、普通状态 JSON 或文档。

1. 建立前再次核对 TUN 消费者已可立即接管 fd；
2. 准备 `destroy()` 与 `aa force-stop` 即时回滚；
3. 建立后立即启动 TUN 消费者；
4. 使用另一个 App 做联网哨兵；
5. 任何失败立即停止，不继续组合试探；
6. 验证前后台、进程死亡和网络切换后系统网络均恢复。

具体任务见 [`todo.md`](./todo.md)。
