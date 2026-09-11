# NetBird HarmonyOS 当前状态与 TODO

> 最后更新：2026-09-09
> 开发环境：仅 Windows；项目、Go、DevEco Studio、OHOS NDK 和设备调试均在 Windows 侧完成。

## 当前结论

**生产显式 VPN、真实端到端数据面与公网 P2P 已完成真机闭环：只有同包 `CONTROL_CONNECT` 可 create，Extension 启动不自动 create；新版 Network route、matching fd-consumed、WireGuard 握手、Tx/Rx、后端 HTTP 响应、routing peer `connectionType=P2P`、Disconnect `1→0`、failure=0 和最终进程=0 均已验证。**

当前安全边界：

1. `client/harmony/nbharmony.go` 真实构造 `client/internal.ConnectClient`；Extension 仅在 app-private config 已存在或一次性 setup-key 导入成功后，显式进入标准 real Management + Signal 的 `RunOnHarmonyWithFDProvider` preparation。
2. 模块已注册 `type: "vpn"` 的 `NetbirdVpnExtensionAbility`，它运行在独立 `org.huangedehw.nbconnect:vpn` 进程。
3. UI 和 VPN 进程通过同包定向 Dynamic CommonEvent 交换版本化 JSON；UI 发送 `status-request`，VPN 进程返回自己进程内的权威 `coreStatus()`。
4. Extension 可成功调用 API 22+ `protectProcessNet()`，保护该进程之后创建的全部 tunnel/control socket。
5. **`PRODUCTION_ENABLE_EXPLICIT_VPN_CONNECT=true` 只接受同包显式 `CONTROL_CONNECT`；Extension 启动不 create。`DEBUG_ENABLE_REAL_VPN_FD=false` 与 `DEBUG_ENABLE_AUTOMATIC_VPN_RECONFIGURATION=false` 保持关闭。**
6. UI 本地 Core 仅作回归显示；远端状态明确来自 `deviceName=nbconnect-vpn`。
7. `coreConnect()` 继续返回 `-100`；生产显式宿主状态机使用 prepared config 执行 `create → versioned provide → matching fd-consumed`。
8. ArkTS 仅枚举 `NET_CAPABILITY_NOT_VPN` 网络并构造内存 `VpnConfig`；普通 polling 不触发 create/recreate，只有用户显式 Connect 可建立系统 VPN。
9. Extension 失败、Disconnect 与停止统一经过幂等 rollback；每次真机 create 另有外部 force-stop watchdog。
10. Harmony late-fd 路径会在 `wgInterfaceCreate` 前启动唯一 management Sync：首个含 NetworkMap 的响应先投影 selected static client routes 与 DNS/search domains，再在接口 Up 后按原顺序回放；因此初始 `VpnConfig` 不再缺少首包配置。
11. 运行期 route/DNS desired revision 与宿主 destroy/recreate 协调器已实现；自动重配 gate 当前保持 false，不会在后台自行 destroy/create。
12. 模块声明 `ohos.permission.INTERNET`。Harmony gRPC 已通过 build-tag 平台分派强制使用标准 `net.Dialer`，避免 `GOOS=linux` 误入 Linux user/root dialer；真机已在 Dial override 为空、relay=0、HDC rport=0 时直连 Management、Signal 和 NetworkMap。Dial override 仅保留为受限调试能力，不参与生产数据面。
13. combined server 已启用 `supportedSyncMessageVersions: 1`。NetBird `0.78.0` SQLite direct-peer Router 查询会丢失 `peer_groups=[]` 的行，已使用必须保留的专用单-peer组 `nbconnect-router-workaround` 绑定 Router；升级并修复 SQL 前不得删除该组或恢复 direct-peer。
14. HTTP 目标会返回重定向；探测器对明文 HTTP 使用系统 TCP socket 读取首个 HTTP/1.x 状态行，不关闭 TLS 校验、不记录 URL/body，最终验证 `code=301`。
15. 公网 P2P 根因已修复：`protectProcessNet()` 后普通 UI UDP 可到达 routing peer，但 VPN 进程 UDP marker 为 0；Harmony 现通过 `OH_NetConn_BindSocket` 只把 WireGuard/ICE 共享 UDP socket 绑定到当前默认物理网络，同时 ICE build-tag 使用平台 `ExternalIFaceDiscover` 而非 `GOOS=linux` 的系统接口枚举。真机计数 `bind attempts=2, succeeded=1, failed=0`（采样时第二次调用仍进行中），ICE `agents=3, offers=2, gathers=2, gatherFailed=0, localCandidates=4, remoteCandidates=3`，routing peer 最终 `connectionType=P2P`。临时 UDP marker 探针已移除。

### 强制安全规则

真机发现：`VpnConnection.create()` 即使最终 reject `2200003 System internal error`，系统也可能先发布 VPN connected 并接管其他应用流量。用户实测京东 App 无法联网。

因此：

- 在 fd-backed Go TUN 读取/写入链路、路由策略和可逆停止流程全部准备好之前，禁止再次调用 `VpnConnection.create()`；
- “无 routes”或 Promise rejected **不能**被当作无流量影响保证；
- 下一次建立系统 VPN 必须单独获得用户确认，并先准备即时回滚命令；
- 发生异常时立即执行：
  ```powershell
  & "D:\Program Files\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" `
    shell "aa force-stop org.huangedehw.nbconnect"
  ```

本次事件收到用户反馈后已立即 force-stop。系统日志确认：

```text
VPN_CONNECTION_STATUS_CHANGED state: 0
vpn status bar status change, newState: false, oldState: true
```

所有 nbconnect 进程当时均已退出，设备 VPN 接管已解除。

## 验证矩阵

| 项目 | 状态 | 证据 |
|---|---|---|
| Windows Go + OHOS clang Core archive | ✅ | `libnbharmony.a` 113,198,882 bytes；header 3,271 bytes |
| generation-safe 动态重配协调器 | ✅ Go/ArkTS/构建/无 VPN 真机自检 | Core debounce/lease/client rebuild；宿主 begin→destroy→restart→create→provide→consume；timeout/stale/create reject全rollback；`VPN_RECONFIGURATION_LIFECYCLE_SELFTEST` |
| 强制 Harmony build tag | ✅ | `go build -tags harmony` |
| eBPF 启动期路径排除 | ✅ | `RLIMIT_PRESENT=False`、`LINK_PRESENT=False` |
| `RunOnHarmony` 入口策略 | ✅ 真机自检 | fd>0、IFaceDiscover、network/DNS adapter、state/cache 路径必填；`Harmony platform policy OK` |
| Harmony 平台服务隔离 | ✅ Go/交叉编译 | mobile DNS host、route prefix notifier/no-system SysOps、userspace firewall/no-op firewalld、monitor skip |
| 真实 `ConnectClient` 构造 | ✅ | Core `Idle`，engine 未启动 |
| 平台状态 C ABI / N-API | ✅ | `NbCoreSetPlatformState`、`NbCoreClearPlatformState` |
| 平台配置 polling bridge | ✅ 真机 | `coreSetInterfaces/snapshot/rollback/selfTest`；非 VPN 接口 `count=1`、`interfaceRevision=1` |
| late-fd 两阶段状态机 | ✅ 无 VPN真机自检 | `RunOnHarmonyWithFDProvider`、context cancel、generation、await/provide/consume/rollback；`NB_LATE_FD_SELFTEST_DONE` |
| 首个 NetworkMap prefetch | ✅ Go/交叉编译/真实 Management 真机 | single Management Sync；`VPN_MANAGEMENT_NETWORK_MAP_READY`；`authentication.state=network-map-ready`、`preparationState=awaiting-fd`、`configRevision=5` |
| 安全 setup-key / config 恢复 | ✅ 真机 | app-native 0600 一次性 import；联网前删除；注册成功后仅持久化生成 config；进程重启后 `state=configured`，不重复注册 |
| Management + Signal transport | ✅ 真机生产直连 | Harmony build-tag 使用标准 `net.Dialer`；Dial override为空、relay=0、rport=0；private auth、Signal、components NetworkMap ready |
| Harmony 公网 P2P | ✅ 真机 | UI UDP marker 到达 `eth0`；VPN process 仅 `protectProcessNet` 时 marker=0，按 WireGuard UDP fd 执行 `OH_NetConn_BindSocket` 后 bind 无失败；Harmony ICE 使用 `ExternalIFaceDiscover`，双向候选非零；routing peer `Connected/P2P`、ICE type/endpoint present、Tx/Rx active |
| 受限 SNI relay | ✅ 历史调试能力，生产不依赖 | override 仍只接受loopback/private地址并保留TLS authority；最终生产直连验证中未启动relay |
| 前后台与物理网络切换 | ✅ 真机 | 后台60秒VPN持续；Wi-Fi→蜂窝→Wi-Fi均无down/failure，NetworkMap、handshake=2、Tx/Rx和HTTP自动恢复 |
| 30分钟稳定性 | ✅ 真机 | 1815秒/7点：双进程、map/peer/TUN全部通过；failure/down/thread-block=0；RSS无持续增长，线程60→57 |
| 进程异常恢复 | ✅ 真机 | 活动VPN force-stop后进程=0、系统VPN state=0；无中继重新认证/Connect/HTTP成功，正常Disconnect再回到0 |
| 调试防锁屏 | ✅ 真机 | 前台 window `setWindowKeepScreenOn(true)`；`DEBUG_KEEP_SCREEN_ON_ENABLED` |
| preparation C ABI / N-API | ✅ 构建/策略验证 | `coreStartPreparation/coreProvideTunFD`；普通 status 只含 running/state/generation；常规 Extension 不调用 |
| 内存 `VpnConfig` / 无 create 策略 | ✅ 真机 | `NB_PLATFORM_BRIDGE_SELFTEST_DONE`、`VPN_CREATE_DISABLED`；无 `VPN_CONNECTION_STATUS_CHANGED` |
| rollback 状态机 | ✅ 真机 | timer 停止、observer/command unsubscribe、Go desired config 幂等清理、VPN PID 退出 |
| VPN Extension 打包 | ✅ | signed HAP `module.json` 包含 `type: "vpn"` |
| VPN Extension 独立进程 | ✅ | UI PID 15459；`:vpn` PID 15914 |
| 同包定向 IPC v2 | ✅ 构建/真机 | status + initialize/configure/connect/disconnect/shutdown；显式 coordinator 覆盖成功、重复请求和失败 rollback；生产策略仅允许同包用户命令，启动不自动 create；正式 Connect/Disconnect 真机通过 |
| Components NetworkMap v1 | ✅ 真机 | `advertisedVersion=1`、`syncVersion=1`、resources=3、routers=2、policies=3、decodedRoutes=3 |
| 真实网关 route | ✅ 真机 | routeCount=3、routedPeers=2、assignedRoutes=3；SQLite direct-router bug 使用专用 peer-group workaround |
| WireGuard 数据面 | ✅ 真机 | known=7、connected=2、withHandshake=2、Tx/Rx active；tunRead=15、tunWrite=5、tunInvalid=0 |
| 端到端 HTTP | ✅ 真机 | 系统 TCP socket 读取首个 HTTP 状态行；`VPN_E2E_HTTP_PROBE_OK code=301`，不记录目标或响应 body |
| 最终安全生命周期 | ✅ 真机 | matching fd-consumed；系统 VPN `1→0`；Disconnect confirmed；failure=0；watchdog停止；最终进程=0 |
| 可信连接状态与 Peer 明细 UI | ✅ 真机 | 分层 `准备/连接中/等待握手/P2P/Relay/失败/断开中`；未握手不显示 P2P；混合场景顶部 `VPN 已连接 · 直连1 · 中继1`，Peers 逐节点 `office-nb-sh=Relay`、`tc-sh=P2P`，连接详情仅 `WireGuard` |
| 断开后重连 | ✅ 真机 | 连续两轮 `C1→D1→C2`、`D2→C3` 全部成功；最终 `APP_STOPPED=True`、`TUN=0` |
| 重连根因修复 | ✅ 真机+诊断 | 服务端 `no peer auth`（重新注册后带 `accountID` 登录 1.2ms）；`ConnectClient` 不可二次 Run（`engine run returned without tunnel fd after 1ms`），Disconnect 后停止 Extension 以全新进程重连；修复 `STOPPED` 误置 `extensionStarted` |
| 请求关联 | ✅ | 自动请求 `1788484246618-573008`、手动请求 `1788484276326-510901` 均原样返回 |
| VPN 权威 Core | ✅ | 响应为 `deviceName=nbconnect-vpn`、`clientStatus=Idle` |
| `protectProcessNet()` | ✅ | `VPN_PROCESS_PROTECTED_NO_TUN` |
| Extension 启动不自动建立系统 VPN | ✅ | 启动/认证/preparation 期间无 `VPN_CONNECTION_STATUS_CHANGED`；仅显式 Connect 后状态变为1 |
| Extension 停止 | ✅ | `VPN_EXTENSION_STOP_OK`、`VPN_EXTENSION_DESTROY`；VPN PID 退出，UI PID 15459 留存 |
| 连接边界 | ✅ | `coreConnect()` 返回 `code=-100` |
| WireGuard/runtime 回归 | ✅ | `NB_SELFTEST_DONE`，UI PID 56984 保持存活 |
| fd TUN adapter 单元测试 | ✅ | Windows `go test ./client/harmony/fdtun`：5 项 PASS |
| fd TUN adapter 真机自检 | ✅ | socketpair raw packet read/write、dup ownership、close cancellation；`NB_FDTUN_SELFTEST_DONE` |
| Harmony interface factory | ✅ | 真机 `Harmony interface factory OK`；无 `/dev/net/tun`、assignAddr、Linux netlink/UAPI |
| fd 注入 fail-closed | ✅ | nil/0/negative fd 拒绝；零值 `MobileDependency` 不把 stdin 当 TUN；fd42 注入测试交叉编译 |
| TLS patch | ✅ | clean build 成功；signed HAP 40,007,600 bytes；stripped `libnetbird.so` 38,051,272 bytes；`TPREL64_FOUND=False` |
| 受控真实系统 TUN fd | ✅ 真机调试 | 唯一一次 create：generation=1、configRevision=5、`fd-consumed`、`O_NONBLOCK=true`、raw read=49/write=0/invalid=0；15 秒 destroy、VPN state 1→0、watchdog 后进程数 0 |

## 已完成

### Core 与构建

- [x] 真实使用 `profilemanager.ConfigFromJSON`、`peer.NewRecorder`、`netevents.NewManager`、`internal.CtxInitState`、`internal.NewConnectClient`。
- [x] C ABI：
  - `NbCoreInit`
  - `NbCoreSetConfig`
  - `NbCoreSetPlatformState`
  - `NbCoreClearPlatformState`
  - `NbCoreSetInterfaces`
  - `NbCorePlatformSnapshot`
  - `NbCoreStartPreparation`
  - `NbCoreProvideTunFD`
  - `NbCoreBeginReconfiguration`
  - `NbCoreRestartPreparation`
  - `NbCoreProvideTunFDForGeneration`
  - `NbCorePlatformRollback`
  - `NbCorePlatformSelfTest`
  - `NbCoreStatus`
  - `NbCoreConnect`
  - `NbCoreShutdown`
  - `NbCoreTunSelfTest`
  - `NbCoreSelfTest`
  - `NbFreeString`
- [x] 平台状态动态报告：Extension、process protect、TUN fd、DNS、network change 和 last error。
- [x] mutex 单例、panic recovery、JSON 响应和私钥脱敏。
- [x] `-tags harmony` 排除 `cilium/ebpf/rlimit`、`ebpf/link` 启动路径。
- [x] CMake `POST_BUILD` 自动 TLS patch；clean Hvigor build、strip、签名成功。

### VPN Extension

- [x] 本机 SDK 6.1.1(24) API 核对：
  - `startVpnExtensionAbility` / `stopVpnExtensionAbility`：API 11；
  - `createVpnConnection(context)`：API 11；
  - `VpnConnection.create(config): Promise<number>`：返回 TUN fd；
  - `protect(socketFd)`：API 11；
  - `protectProcessNet()`：API 22；
  - `destroy()`：可逆销毁。
- [x] `module.json5` 注册 `NetbirdVpnExtensionAbility`，类型为 `vpn`。
- [x] Extension 构造控制对象、调用 `protectProcessNet()` 并准备内存 `VpnConfig`；Extension 启动与普通 polling 不 create，只有同包生产显式 `CONTROL_CONNECT` 可调用真实 create。
- [x] 页面提供“准备平台进程 / 停止平台进程”，不再提供 TUN 探针。
- [x] 验证 Extension 在独立 `:vpn` 进程，UI 与 Extension 各自加载独立 N-API/Go 单例。

### 跨进程状态控制面

- [x] 新增 `ets/vpn/VpnIpc.ets`，定义同包定向 `VPN_COMMAND` / `VPN_STATUS` Dynamic CommonEvent。
- [x] 协议升级为 `version=2`，保留 `kind/requestId/payload`；新增 `control-request/control-response`。control payload 只允许单一 `command` 字段，旧版本、未知命令和附加 credential/config 字段 fail closed；发布/订阅仍双向限制当前 bundle。
- [x] UI 先订阅状态，再启动 Extension；自动及手动发送 `status-request`。
- [x] VPN 进程订阅命令并以相同 `requestId` 返回自己进程内 `netbird.coreStatus()`。
- [x] `initialize/configure/connect/disconnect/shutdown` 使用逐请求 `control-response`；响应增加非敏感 `lifecycleState`。UI 先登记 pending 再发布，5 秒超时并校验 command/requestId。Extension 串行执行，缓存最近 64 项；相同 requestId/command 幂等重放，不同命令冲突返回 `-409`。
- [x] 新增显式连接 coordinator：`ready → connecting → connected → disconnecting → disconnected`，重复 connect/disconnect 无副作用，任一失败统一 rollback。宿主 Connect 接入 prepared config 的 create/versioned provide/consumed；Disconnect 接入幂等 adapter rollback。生产策略 `PRODUCTION_ENABLE_EXPLICIT_VPN_CONNECT=true` 仅接受同包显式用户命令，Extension 启动不自动 create；底层 `coreConnect()` 仍保持 `-100`。
- [x] UI 区分“本地回归 Core”和“VPN 进程权威状态”，不传输私钥或配置秘密。
- [x] 兼容 Harmony 成功回调的 `error === null`；原实现直接读取 `error.code` 曾导致 UI 与 VPN 进程同时 TypeError，现已在 publish/subscribe/unsubscribe 全部做 null 检查。
- [x] 真机验证 `ready`、自动/手动状态请求响应、Extension API 停止确认、子进程退出及 UI 留存。`stopped` 在 `onDestroy` 中为尽力发布；可靠停止确认以 `stopVpnExtensionAbility()` 成功返回和 VPN PID 退出为准。

### ArkTS ↔ Go 平台配置桥（不建立系统 VPN）

- [x] 新增 `client/harmony/platform_adapter.go`，线程安全实现 `ExternalIFaceDiscover`、`NetworkChangeListener`、`MobileDNSManager`。
- [x] ArkTS 使用 NetworkKit `getAllNets/getNetCapabilities/getConnectionProperties`，只保留 `NET_CAPABILITY_NOT_VPN` 网络；新增普通权限 `ohos.permission.GET_NETWORK_INFO`。
- [x] 接口名、MTU、prefix 经 Go 验证并稳定排序/去重；物理接口 `interfaceRevision` 与 desired config `revision` 分离。
- [x] Go 聚合 tunnel IPv4/IPv6、routes、DNS、search domains 和 MTU；Harmony `wgInterfaceCreate` 通过可选 `SetMTU(int)` capability 转发实际 engine MTU，ArkTS 每 250ms 拉取 snapshot，只在内存构造 `VpnConfig`。
- [x] C ABI/N-API：`coreSetInterfaces`、`corePlatformSnapshot`、`corePlatformRollback`、`corePlatformSelfTest`。
- [x] 原始接口/address/route/DNS snapshot 不进入普通 `coreStatus()`、CommonEvent 或 hilog；真机扫描 `RAW_PLATFORM_DETAIL_MATCHES=0`。
- [x] rollback 幂等停止 timer、unregister observer、清 desired config；create 前记录 `vpnCreateAttempted`，attempted/created 任一为 true 都执行 `destroy()`。
- [x] 真机修复 NetworkKit `register` 成功回调传 `undefined` 的差异；判断同时兼容 `undefined/null`。
- [x] 真机：`interfaces=1`、`interfaceRevision=1`、`desiredRevision=0`；`NB_PLATFORM_BRIDGE_SELFTEST_DONE` 与联合 `NB_PLATFORM_ADAPTER_SELFTEST_DONE` 通过。

### late-fd 两阶段准备（不建立系统 VPN）

- [x] 新增 `device.TunFDProvider.WaitTunFD(context.Context)`，Engine context cancel 与 rollback 均可解除阻塞。
- [x] 新增 `ConnectClient.RunOnHarmonyWithFDProvider`；旧 `RunOnHarmony(fd)` 继续兼容。
- [x] Harmony `NewWGIFace` 接受 static fd 或 provider；`TunDevice.Create` 才等待 fd，provider 返回 `fd<=0` 立即拒绝。
- [x] Engine 在 fd wait 前发布 overlay IPv4/IPv6、MTU、内存 DNS IP；adapter 自动加入 masked overlay base route。
- [x] adapter 状态：`awaiting-fd`、`fd-provided`、`fd-received`、`fd-consumed`、`cancelled`、`rolled-back`，并维护 generation；只有 `fdtun.NewFromFD` 成功 dup 后才 ack consumed，rollback 与 provide/consume 竞态 fail closed。
- [x] C ABI/N-API：`coreStartPreparation(state, cache, log)`、`coreProvideTunFD(fd)`；普通 `coreStatus()` 只公开 preparation running/state/generation。
- [x] ArkTS `startCorePreparation` 等待 `awaiting-fd + configReady`，超时调用统一 rollback；常规 Extension 不调用该方法。
- [x] Go 完整测试、Harmony iface/internal 交叉编译和 signed-HAP 自检通过；真机报告 `Harmony late-fd duplication acknowledgement OK` 与 `NB_LATE_FD_SELFTEST_DONE`，无系统 VPN 状态变化。
- [x] Harmony provider 路径在 fd wait 前启动唯一 management Sync；首个 NetworkMap（legacy/components）先投影 selected static client routes 与 DNS/search domains，config-only 前置响应缓存，接口 Up 后再按原顺序 `handleSync` 回放。
- [x] prefetch 30 秒超时、stream close/error、context cancel 均 fail closed；不启动第二条 Sync，不在 fd 前应用 peers/firewall/route handlers。
- [x] Windows 四包完整测试与 Harmony arm64 交叉编译通过；真机 signed-HAP synthetic projection 报告 `Harmony initial NetworkMap preparation OK`、`NB_INITIAL_MAP_PREFETCH_SELFTEST_DONE`，无系统 VPN 状态变化。
- [x] 后续 NetworkMap route/DNS revision 已实现 250ms debounce/coalescing、独立 config revision、generation/stale rejection、旧 fd lease release ack、fresh client rebuild、新 fd versioned provide/consumed ack 和失败 fail-closed。
- [x] Core API 分为异步 `begin` 与显式 `restart`，给未来宿主在中间安全 destroy/recreate 平台 VPN；旧 preparation goroutine 无权清理新 generation。
- [x] Go 单测、Harmony arm64 c-archive、N-API/ArkTS 编译和 signed-HAP 打包通过；真机 `NB_RECONFIGURATION_SELFTEST_DONE`、matching consumed/released lease、Extension start/stop rollback 和 VPN 子进程退出均通过。
- [x] 最终真机日志：`RAW_PLATFORM_DETAIL_MATCHES=0`、`VPN_CONNECTION_STATUS_CHANGED_MATCHES=0`、`FAILURE_MARKER_MATCHES=0`；`VPN_CREATE_DISABLED` 保持有效。

### fd-backed TUN adapter（生产显式 Connect 已启用；自动 create 禁用）

- [x] 新增 `client/harmony/fdtun`，完整实现 wireguard-go `tun.Device`：单包 read/write、offset、MTU/name、EventUp/EventDown、BatchSize=1、close/cancel。
- [x] Harmony `NewFromFD` 对平台 fd 执行 `dup`；Go 只关闭副本，原 fd 继续归 `VpnConnection` 生命周期所有。
- [x] 为 Go netpoll 取消阻塞 I/O 设置 nonblocking。注意 `O_NONBLOCK` 属于共享 open-file description，因此原 fd 的状态标志也会变化；接真实 fd 前必须确认平台侧不依赖 blocking I/O。
- [x] Windows `net.Pipe` 单测 5 项通过；`-race` 因 Windows 环境没有 `gcc` 未执行，非测试失败。
- [x] 新增 `NbCoreTunSelfTest` / `coreTunSelfTest` 和 UI 安全按钮；真机使用 `AF_UNIX SOCK_DGRAM socketpair` 验证 raw packet 读写、dup 关闭后原 fd 可用、close 取消阻塞 read。
- [x] 真机日志：`NB_FDTUN_SELFTEST_DONE`；该测试不调用任何系统 VPN API、路由或 DNS。
- [x] 新增 Harmony 专用 `iface_new_harmony.go` / `device_harmony.go` / `iface_destroy_harmony.go`；Go factory 只接受 `fd>0` 或非空 context-aware provider。
- [x] Linux `iface_new`、userspace TUN device 和 netlink Destroy 均以 `!harmony` 排除；Harmony 不探测 kernel、不调用 `tun.CreateTUN`、不 assignAddr、不创建 UAPI socket。
- [x] `engine.newWgIface` 改用编译期 `configureMobileIFaceArgs`；Android/iOS 语义保持，Harmony 零值依赖不注入 stdin fd0。
- [x] Harmony factory/internal 定向测试交叉编译成功；设备禁止执行 `/data/local/tmp` 测试二进制，因此通过签名 HAP 中的完整 factory 自检执行。
- [x] 自检 transport 从会查询 netlink 的 `stdnet` 改为纯内存 Pion `vnet`；真机返回 `Harmony interface factory OK`。
- [x] 独立 adapter 代码审查结论 PASS，无 blocking issue。

### 安全认证与真实 Management NetworkMap（不建立系统 VPN）

- [x] UI 密码输入经 native API 原子写入 app-private `0600` 一次性 import；ArkTS 立即清空 setup-key state，CommonEvent 只发送普通 Extension start。
- [x] VPN 进程在 `protectProcessNet()` 后读取并删除 import，再异步注册；成功后只持久化生成的 NetBird config/private keys。
- [x] `module.json5` 补齐 `ohos.permission.INTERNET`；缺少该权限时 Go socket 一律失败，这是早期 timeout 的根因之一。
- [x] HDC reverse listener 只在 shell 网络上下文可达；最终调试链路为 Windows WLAN `192.168.12.0/24` 私网 relay。runtime override 仅接受 loopback/private IP，不进入持久 config/status。
- [x] 修复临时 relay 的 half-close：必须等待两个 `io.Copy` 方向完成，否则 gRPC request half-close 会提前截断 Login/Sync response。
- [x] 无 credential 时直接恢复已有 config；用户显式再次导入 setup key 时使用原私钥执行 `Auth.Login`，服务端仅在需要时重新登记同一公钥，不生成新身份。
- [x] 真机证据：`VPN_PRIVATE_AUTH_READY state=authenticated`、`VPN_MANAGEMENT_NETWORK_MAP_READY ... configRevision=5 preparationGeneration=1`、`authentication.state=network-map-ready`、`managementConnected=true`、`signalConnected=true`、`preparationState=awaiting-fd`。
- [x] `shared/signal/client.ContextWithDialAddress` 已保留原 Signal gRPC target/TLS authority 并覆盖 socket destination；production code 已无 `ManagementPrefetchOnly` 和 Signal mock branch。
- [x] 零系统 VPN 证据：`VPN_CREATE_DISABLED`、`VPN_CONNECTION_STATUS_CHANGED_MATCHES=0`、`VPN_CREATE_CALL_MATCHES=0`；停止后 `APP_PROCESS_COUNT=0`。
- [x] 隐私扫描：`HILOG_SETUP_KEY_MATCHES=0`、`RELAY_SETUP_KEY_MATCHES=0`。
- [x] 已删除 `ManagementPrefetchOnly` 和 Signal placeholder；真实 Signal transport 在 Engine/Management Sync 前建立，并通过 `signalConnected=true` 与独立 full-duplex SNI relay 会话完成真机验证。

## 关键架构结论

### Core 所有权

真实 NetBird Core 必须由 VPN Extension 进程拥有，因为：

- TUN fd 在 Extension 进程获得；
- `protectProcessNet()` 只保护调用它的 VPN 进程；
- Go 网络 socket 必须在该保护之后、同一进程中创建；
- UI 进程中的 `coreStatus()` 不是 VPN 进程 Core 的状态。

后续 UI 只能作为控制面，通过跨进程通道向 VPN 进程发送 init/connect/stop/status 命令。

### 权限

SDK 中 `ohos.permission.MANAGE_VPN` 是 `system_grant/system_basic/SYSTEM`，但公开第三方 VPN API 没有 `@permission` 声明。真机系统授权对话框与 Extension 启动已成功，当前不在普通 HAP 中声明该系统权限。

### eBPF / Rosenpass

Harmony build 继续必须带 `-tags harmony`。基础 `github.com/cilium/ebpf` 仍经 Rosenpass 间接存在；启用 Rosenpass 前必须禁用其 BPF 路径或实现 Harmony 方案。

## 下一步（按优先级）

### P0：跨进程控制面

- [x] 实现 UI ↔ `:vpn` 进程同包定向 Dynamic CommonEvent 状态通道。
- [x] VPN 进程拥有权威 Core；UI 通过 `status-request` 获取其原始 `coreStatus()`。
- [x] 状态通道已覆盖 Extension ready、process protect、Core/TUN/DNS/network change 状态和 last error。
- [x] Extension 停止由系统 API 返回值和子进程退出可靠确认；`onDestroy` 的 `stopped` 事件仅作尽力通知。
- [x] 在保持当前安全边界的前提下完成版本化 `initialize/configure/connect/disconnect/shutdown` 命令、逐请求确认与显式连接 coordinator；协议/fake lifecycle self-test、signed HAP 和无 VPN 真机验证通过。
- [x] 一次性显式 Connect HAP 已验证正式 Connect→connected、不同 requestId 重复 Connect 无重复 create、Disconnect→disconnected，以及重复 Disconnect 无副作用。生产策略现为同包用户命令专用，启动不自动连接；connected/disconnected 各 1、failure=0、watchdog 后进程=0。
- [x] 新增脱敏 peer runtime 摘要：known/connected/withHandshake/聚合 TxRx，不包含 IP、FQDN、公钥或握手时间；Go 单测验证无标识泄漏。
- [x] 已从本地凭据动态使用用户提供的网关与后端 HTTP 目标完成真机闭环：matching fd-consumed、系统 VPN `1 → 0`、failure=0；`advertisedVersion=1, syncVersion=1, decodedRoutes=3, routers=2`，`known=7, connected=2, withHandshake=2, Tx/Rx active`，`routeCount=3, assignedRoutes=3, tunRead=15, tunWrite=5, tunInvalid=0`；HTTP 返回 `VPN_E2E_HTTP_PROBE_OK code=301`，最终进程=0。

### P1：fd-backed TUN 数据面（已完成；自动 create 继续禁用）

- [x] 调研 NetBird iOS fd TUN adapter 与 `RunOniOS` 可复用边界；确认 Harmony 不能直接套用 iOS runtime 分支。
- [x] 实现 Harmony fd-backed TUN adapter 的 read/write/close/cancel。
- [x] 明确 fd close 所有权，避免 Go 与 `VpnConnection.destroy()` 双重关闭。
- [x] 使用 Windows `net.Pipe` 和 Harmony `SOCK_DGRAM socketpair` 测试数据面，不调用系统 `VpnConnection.create()`。
- [x] 将 adapter 注入 Harmony 专用 engine/interface 创建边界；使用编译期 helper，不依赖 `runtime.GOOS=ios`。
- [x] 隔离默认 Linux TUN 创建、地址分配、netlink Destroy 和 UAPI socket。
- [x] 实现安全 `RunOnHarmony` 入口：拒绝 fd0/负 fd 和缺失 IFaceDiscover、network/DNS adapter、state/cache 路径；普通 `Run` 在 harmony build 返回错误。
- [x] Go DNS/network contract：`MobileDNSManager`、tunnel notifier、mobile DNS host configurator 和 route prefix notifier 已接线。
- [x] 隔离 route manager、firewall、network/WireGuard monitor、netflow conntrack、kernel module、UAPI/fwmask 等 Harmony Linux 系统路径。
- [x] 在 ArkTS VPN 进程实现 NetworkKit `ExternalIFaceDiscover`、DNS/route/address/MTU snapshot 消费者、内存 `VpnConfig` 和统一 rollback；`coreConnect` 仍返回 `-100`。
- [x] 实现 context-aware pre-login/late-fd two-phase：登录后发布 prepared snapshot，在 `TunDevice.Create` 等待 fd，超时/Stop/rollback 可取消。
- [x] 在 create 前预取完整初始 NetworkMap：唯一 Sync stream 首包先构造 static routes/DNS prepared snapshot，接口 Up 后无损回放。
- [x] 实现首包之后 NetworkMap route/DNS revision 的安全重配协调器：debounce、generation、旧 fd shutdown/release、fresh client rebuild、新 fd consumed，禁止旧 config/fd 重新生效。
- [x] 将 begin/restart/versioned-provide 接入显式宿主 destroy/recreate 生命周期协调器；成功顺序和全部失败rollback由 fake lifecycle 真机自检覆盖，automatic gate 默认 false。
- [x] 在明确确认后完成受控真实运行期重配：初始 fd/raw packet 通过，系统完成旧 VPN destroy 与新 VPN create/versioned provide，matching consumed 与新 fd raw packet 均通过；最终 connected/disconnected 各 2、自动 rollback 1、failure 0、进程数 0。
- [x] 宿主先接受 `fd-consumed + applied revision + stable` 终态，协调器要求 consumed target 已清零并在结果保留原请求 target；新 fd stats 在旧 VPN 销毁后、新 VPN 创建前重置。polling/automatic gate 继续为 false。
- [x] 受控真机验证真实 `VpnConnection` fd 为 raw IPv4/IPv6 packet；duplicated fd 经 `F_GETFL` 确认共享 `O_NONBLOCK`，read=49、invalid=0，destroy 后系统 VPN 正常断开。

### P2：首次真实 VPN 闭环

- [x] 用户已授权后续使用 `docs/connectAccount.md` 的真实环境测试；资料只在 VPN 权威进程使用，不回显、不进 hilog/CommonEvent。
- [x] setup key 注册/既有私钥恢复的安全宿主入口与 app-private 持久化已完成；无系统 VPN 状态下真实 Management 认证和完整 NetworkMap 真机通过，凭据未进入 CommonEvent/hilog/status。
- [x] 调试专用 gate 完成首次真实闭环：create 后立即 versioned provide，等待 `fd-consumed + applied revision`，UI TEST-NET probe 产生 raw packet，15 秒自动 destroy，外部 watchdog 兜底。
- [x] 宿主 destroy/recreate 编排已通过 fake lifecycle 与真实系统验证，matching-consumed、第二次 raw packet 和完整网络 rollback 均通过；automatic reconfiguration 保持 false，生产 Connect 仅接受同包显式用户命令并已完成真实端到端验证。
- [x] 调试 gate 在 create 前强制 `awaiting-fd + configReady + generation/revision`，且不以 Promise reject 或空 routes 作为安全保证。
- [x] create resolve 后立即 versioned provide；generation mismatch、timeout、stats 失败或 reject 均 rollback/destroy，另有 force-stop watchdog。
- [ ] 先限制应用范围，再验证路由和 DNS；同时用另一个 App 做联网哨兵。
- [x] 已验证前后台、Wi-Fi/蜂窝双向切换、正常 stop 与活动 VPN 进程 force-stop 均能恢复系统网络；异常终止后无中继重新认证、Connect、HTTP 和正常 Disconnect 再次通过。

### P3：Core 加固

- [ ] Rosenpass Harmony 策略。
- [ ] 结构化跨进程日志与错误码。
- [x] 私钥/登录配置安全持久化：仅生成的 NetBird config/private keys 留在 app-private filesDir；setup-key import 联网前删除。
- [x] GC、goroutine、WireGuard 生命周期和 30 分钟压力测试：1815秒/7点全部通过，RSS无持续增长、线程60→57、failure/down/thread-block=0。
- [ ] 跟踪 `golang/go#71953`，官方动态 TLS 可用后移除 workaround。

## 当前关键文件

- `D:\Code\netbird\client\harmony\nbharmony.go`
- `D:\Code\netbird\client\harmony\platform_adapter.go`
- `D:\Code\netbird\client\harmony\platform_adapter_test.go`
- `D:\Code\netbird\client\harmony\fdtun\device.go`
- `D:\Code\netbird\client\harmony\fdtun\fd_harmony.go`
- `D:\Code\netbird\client\harmony\fdtun\device_test.go`
- `D:\Code\netbird\client\harmony\tun_selftest_harmony.go`
- `D:\Code\netbird\client\iface\iface_new_harmony.go`
- `D:\Code\netbird\client\iface\iface_destroy_harmony.go`
- `D:\Code\netbird\client\iface\device\args.go`
- `D:\Code\netbird\client\iface\device\device_harmony.go`
- `D:\Code\netbird\client\internal\engine.go`
- `D:\Code\netbird\client\internal\engine_harmony_prefetch_test.go`
- `D:\Code\netbird\client\internal\routemanager\manager.go`
- `D:\Code\netbird\client\internal\routemanager\preparation_test.go`
- `D:\Code\netbird\client\internal\mobile_iface_args_harmony.go`
- `D:\Code\netbird\client\internal\mobile_iface_args_harmony_test.go`
- `D:\Code\netbird\client\internal\ebpf\instantiater_linux.go`
- `D:\Code\netbird\client\internal\ebpf\instantiater_nonlinux.go`
- `netbird/src/main/ets/vpn/VpnIpc.ets`
- `netbird/src/main/ets/vpn/HarmonyPlatformAdapter.ets`
- `netbird/src/main/ets/netbirdvpnextensionability/NetbirdVpnExtensionAbility.ets`
- `netbird/src/main/ets/pages/Index.ets`
- `netbird/src/main/module.json5`
- `netbird/src/main/cpp/napi_init.cpp`
- `netbird/src/main/cpp/types/libnetbird/Index.d.ts`
- `netbird/src/main/cpp/libnbharmony.a`、`libnbharmony.h`
- `netbird/src/main/cpp/CMakeLists.txt`
- `netbird/patch_tls.js`
- `netbird/build/default/outputs/default/netbird-default-signed.hap`

详细命令、架构和真机证据见 [`harmonyos鸿蒙开发文档.md`](./harmonyos鸿蒙开发文档.md)。

## 当前能力与已知缺陷（截至 2026-09-11）

### 已具备
- 多配置管理：每个 profile 独立持有 `netbird-private-<id>.json` / `netbird-state-<id>.json`，切换配置不混用身份。
- setup key 导入：一次性传输文件固定为 `netbird-credential-import.json`（Core 只接受该 basename，之前按 profile 命名导致导入必然失败），并在启动、切换配置、无 key 连接前清理残留，避免跨配置串号。
- 连接流程：带 key 点连接只更新当前配置（不再克隆出同名 profile）；导入前后强制重启 Extension，保证 key 被消费；主动重启期间的 `stopped` 事件不再取消待连接。
- 身份不可用时秒级反馈：Management 返回 `PermissionDenied`/`Unauthenticated` 时立即中止准备并上报 `needs-credential`，UI 区分"从未导入凭据"和"服务端已拒绝该身份"；失败上报附带 core/management/signal 诊断串。
- 连接租约：创建系统隧道前等待 desired 配置稳定（500ms 静默窗）再取租约；租约仍被推进时 UI 自动重启重连一次。
- 自动重配：连接期间检测到 `reconfigurationState=pending` 且隧道配置（地址/路由/DNS/MTU）真实变化时，自动执行 generation-safe 重配，约 2.5 秒内把管理端新增/删除的资源装进系统 VPN，无需用户重连；两次重配最少间隔 10 秒、每次连接最多 3 次，失败则回退为自动重连一次。
- 管理端 nameserver group 生效：真机抓包确认整机 DNS 经隧道转发至 CoreDNS（`100.107.x > 192.168.6.240:53`）；客户端状态页 DNS 字段显示的是内置解析器地址（`100.107.255.254`），管理端 IP 作为其上游，按设计不出现在该字段。

### 已知缺陷
- **域名资源（domain resource）不可用**：`dnsinterceptor` 需向 routing peer 的 DNS forwarder（`<peer>:5353`）转发查询，但该查询用的是 `upstream_general.go` 中无绑定的普通 UDP client；VPN 进程调用过 `protectProcessNet()`，进程内 socket 被钉在物理网络，到不了隧道地址，查询 6 秒超时后回 SERVFAIL。对照实验：同一查询从 UI 进程 29ms 成功、从 VPN 扩展进程超时，从 tc-sh `dig @<peer> -p 5353` 8ms 成功。因此解析失败 → 动态 /32 永不生成 → 该 routing peer 的路由永不出现，相关站点在连接 VPN 后打不开。修法：为 harmony 增加等价于 `upstream_ios.go` 的绑定实现（源地址绑隧道 IP + `OH_NetConn_BindSocket` 绑到 VPN 网络）。
- **fake IP + 用户态 DNAT 未启用**：`internalDnatFw()` 有 `runtime.GOOS != "android"` 硬判断，harmony（`GOOS=linux`）被挡住，域名资源只能按真实 IP 逐条加 /32。由于鸿蒙系统 VPN 配置不能原地更新，每条新 /32 都要销毁重建隧道（约 2.5 秒中断），短时间访问多个域名会连续重建并吃满重配上限。修法：放开该判断走 `240.0.0.0/8` 假地址段（`uspfilter` 已实现 `AddInternalDNATMapping`），ArkTS 侧预置该段聚合路由并在重建判定中做覆盖归并。
- Networks 的域名资源在服务端被硬编码 `KeepRoute: true`（`networks/resources/types/resource.go`），动态 /32 只增不减，加剧上一条。
- search domains 永远落后一轮：引擎在隧道建立后才发布域名资源的 match domains，因此 `configRevision` 稳定高于 `appliedConfigRevision`（观测为 9 vs 6）。已在重建判定中排除 search domains，避免永不收敛的重建循环；代价是该字段不进系统 VPN 配置。
- Go 侧日志（logrus）既未落 `netbird.log` 也未接入 hilog，DNS/路由层问题只能靠对照实验和服务端抓包定位。
- 临时（ephemeral）setup key 注册的 peer 离线约 10 分钟后被服务端回收，重连必须重新导入 key；长期联调建议使用非 ephemeral key。
- 真机联调时 hdc 在 VPN 建立/断开附近偶发掉线，需重新插拔或重连调试。
