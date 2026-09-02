## 文档链接
1. 管理网络连接： https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-connection-manager
2. 管理网络连接（c/c++）: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/native-netmanager-guidelines
3. 连接vpn：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension
4. Native Developlment Kit（NDK）开发文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ndk-development-overview

## 项目目标

移植 NetBird（开源 WireGuard mesh VPN 客户端）到 HarmonyOS/OpenHarmony，实现鸿蒙原生 VPN 客户端。

NetBird 源码位于 `../netbird/`。

## 架构分析（NetBird 现有客户端）

NetBird 的核心逻辑（连接管理、WireGuard、NAT 穿透、路由、DNS、gRPC 通信）全部是纯 Go 代码，位于 `client/internal/...`，并深度依赖 `wireguard-go`（userspace WireGuard 实现）。

平台绑定层（`client/android`、`client/ios/NetBirdSDK`）通过 **gomobile** 把 Go 能力导出为 `.aar`（Android）/ `.framework`（iOS），供 Kotlin/Swift 调用。鸿蒙没有 gomobile 支持。

Android 平台特有的两个关键适配点（鸿蒙需要等价实现）：
1. **TUN 设备创建**：Android 侧通过 `VpnService` 拿到 tun fd，传给 Go 层 `device.TunAdapter`（见 `client/iface/iface_create_android.go`、`client/iface/device_android.go`）。
2. **Socket 保护**：VPN 建立后，Go 内部用于 STUN/TURN/gRPC 的 socket 必须绕过 VPN 隧道，否则会死循环。Android 用 `VpnService.protect(fd)` 实现（见 `client/net/protectsocket_android.go`）。鸿蒙的 `net-vpnextension` 是否有等价 API，待确认。

## 技术方案对比

**方案A（推荐）：Go 编译为 C ABI 库 + NDK 桥接**
- 用 `go build -buildmode=c-archive`（注意：非 c-shared，原因见下）把 `client/internal` 相关逻辑编译成 `.a` + `.h`
- 鸿蒙侧用 Native C++（NDK）静态链接该 `.a`，写桥接层
- 通过 N-API 把 native 能力暴露给 ArkTS UI
- TUN fd 通过鸿蒙 VPN Extension 拿到后，经 C 桥传给 Go
- 复用度最高，业界常见做法（类似部分项目移植 Go 网络库到不支持 gomobile 的平台）

**方案B：纯 native/ArkTS 重写核心逻辑**
- 需重写 WireGuard 协议栈、ICE/STUN/TURN、gRPC 客户端等，工作量巨大，不推荐

**关于"找 WireGuard C 库"**：调研后确认不是捷径。
- `embeddable-wg-library`（WireGuard 官方）只是配置管理工具，不含协议实现，无法使用
- `boringtun`（Cloudflare，Rust）是真正的 userspace WireGuard 实现，但 NetBird 的路由/DNS/信令/NAT穿透等逻辑仍是 Go 写的且与 wireguard-go 深度耦合，换库不能减少工作量，反而需要重写更多东西
- 结论：复用现有 Go 代码（方案A）仍是更优路径，真正的瓶颈是 Go 交叉编译到鸿蒙的可行性，而非协议库选型

## 关键技术风险：Go runtime 与 musl (OHOS) 的 TLS 兼容性问题

**已确认的问题（非推测，有直接证据链）：**

1. Go 官方 issue [golang/go#71953](https://github.com/golang/go/issues/71953)（状态：Open，未修复，仅 proposal 阶段）：Go runtime 目前只支持 initial-exec (IE) 和 local-exec (LE) 两种 TLS 模型，**不支持 general dynamic (GD) 模型**。这导致 `c-shared`/`c-archive` 编译出的库在 **musl libc** 系统上，若不用 `LD_PRELOAD` 强制预加载，直接 `dlopen()` 会报错：
   ```
   initial-exec TLS resolves to dynamic definition
   ```
2. OpenHarmony NDK 底层 libc 是 **musl 的 fork**（Rust 官方文档、`rust-lang/libc` PR 均确认："OpenHarmony uses a fork of musl"）。
3. 直接证据：有开发者在鸿蒙6上把 sing-box（同样是 Go 写的网络代理内核）编译成 `.so`，鸿蒙 native C++ 调用时遇到了完全相同的 `initial-exec TLS resolves to dynamic definition` 报错（[SagerNet/sing-box#3681](https://github.com/SagerNet/sing-box/issues/3681)，该 issue 最终 "closed as not planned"，未解决）。

**结论**：用 `go build -buildmode=c-shared` 生成 `.so`，通过鸿蒙 native 侧 `dlopen()` 动态加载 —— **这条路目前基本走不通**，是 Go runtime 层面的系统性限制，非 NetBird 或个人环境问题。

**可能的规避方向（未验证，需实测）**：
- 改用 `buildmode=c-archive`（静态库 `.a`），在编译期静态链接进鸿蒙的 native `.so`/可执行文件，而不是运行时动态加载。因为符号在链接期解析，理论上可能绕开这个动态加载时的 TLS 重定位问题。这是目前最有希望的方向，**必须先做最小验证才能确认可行**。
- 等待 Go 官方修复 #71953（无时间表，不能指望）。

## 本机环境确认（已验证）

- 开发机：Windows + WSL2（Linux 6.6.87.2-microsoft-standard-WSL2），当前 shell 运行在 WSL2 内
- DevEco Studio 已安装：`/mnt/d/Program Files/DevEco Studio`
- OpenHarmony Native NDK 已安装，路径：
  ```
  /mnt/d/Program Files/DevEco Studio/sdk/default/openharmony/native
  ```
- NDK 内 clang 版本：`OHOS (dev) clang version 15.0.4`，sysroot 位于 `<NDK>/sysroot`
- 目标专用编译器 wrapper（位于 `<NDK>/llvm/bin/`）：
  - `aarch64-unknown-linux-ohos-clang`（真机主流架构，最重要）
  - `armv7-unknown-linux-ohos-clang`
  - `x86_64-unknown-linux-ohos-clang`（模拟器）
  - `loongarch64-unknown-linux-ohos-clang`
- **重要坑**：这套 NDK 里的 `clang` 二进制是 **Windows PE 可执行文件**（`clang.exe`，target 是 `x86_64-w64-windows-gnu` 宿主），不是 Linux ELF。
  - 目标专用 wrapper 脚本（如 `aarch64-unknown-linux-ohos-clang`）是 shell 脚本，内容为 `exec $SOURCE/clang -target aarch64-linux-ohos --sysroot=... "$@"`，但同目录下没有 Linux 版 `clang`（无 .exe 后缀的 ELF），在 WSL 里直接执行会失败（报 `exec: /mnt/d/Program: not found`，因路径含空格且找不到目标文件）
  - `clang.exe` **可以**从 WSL 内直接调用并正常返回版本信息（WSL 的 interop 机制支持透明调用 .exe），但目标 wrapper 脚本本身需要按 Linux shell 脚本执行，指向的是不存在的 Linux clang
  - 需要决定：(a) 直接在 Windows 侧（cmd/PowerShell）用 `clang.exe -target aarch64-linux-ohos --sysroot=...` 手动拼命令做验证，绕开坏掉的 wrapper 脚本；或 (b) 想办法在 WSL 里用其他方式调用 clang.exe 交叉编译 Go（cgo 场景下涉及 WSL↔Windows 路径转换，复杂度更高）
- Go 编译器：WSL 内已通过 `apt-get install golang-go` 安装 **Go 1.24**（非最新，但满足验证需求；netbird 主 go.mod 要求版本待核实，若后续正式编译 netbird 代码需要匹配版本）
