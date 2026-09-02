# TODO：验证 Go 交叉编译为鸿蒙 native 可用库

目标：确认 Go 能否交叉编译出 OpenHarmony 可用的 c-archive 静态库，供 native C++ 静态链接调用。这是整个"NetBird 鸿蒙客户端"方案（方案A）能否成立的前提验证。

## 环境现状（已确认，无需重复排查）
- WSL2 + Windows 双环境，DevEco Studio 装在 Windows 侧（`D:\Program Files\DevEco Studio`）
- OHOS NDK 路径：`/mnt/d/Program Files/DevEco Studio/sdk/default/openharmony/native`
- NDK 的 clang 是 **Windows exe**，不是 Linux ELF；目标专用 wrapper 脚本（`aarch64-unknown-linux-ohos-clang` 等）在 WSL 里直接跑不通（指向不存在的 Linux clang）
- WSL 内已装 Go 1.24（`apt-get install golang-go`）
- 已知重大风险：Go runtime 在 musl（OHOS 底层 libc）上用 `c-shared` + `dlopen` 会触发 `initial-exec TLS resolves to dynamic definition` 错误（golang/go#71953，未修复；SagerNet/sing-box#3681 是实际踩坑案例）。因此必须用 **c-archive**（静态库）而非 c-shared 做验证。

## 待办事项

- [ ] **1. 决定交叉编译执行环境**：Windows 侧原生跑（cmd/PowerShell 直接调用 `clang.exe`），还是想办法在 WSL 里驱动 Windows clang.exe（路径转换、interop）。建议优先试 Windows 侧，路径更干净，且未来 DevEco Studio 打包流程本来就在 Windows 上跑。

- [ ] **2. 写最小 Go 测试代码**：一个导出函数（如 `//export Add` 或返回固定字符串），用 `import "C"` + `func main() {}`，为 `-buildmode=c-archive` 做准备。不涉及 netbird 依赖，先纯验证工具链打通。

- [ ] **3. 交叉编译出 .a + .h**：
  ```
  CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
  CC=<NDK>/llvm/bin/aarch64-unknown-linux-ohos-clang \
  go build -buildmode=c-archive -o libtest.a test.go
  ```
  预期产出 `libtest.a` + `libtest.h`。记录：是否报错、报什么错、Go 是否接受这个非标准 GOOS/CC 组合。

- [ ] **4. 鸿蒙 native 侧静态链接验证**：
  - 在 DevEco Studio 建一个最小 Native C++ 工程（或用命令行 clang++ 手动链接）
  - 静态链接 `libtest.a`，调用其导出函数
  - 编译目标：aarch64-linux-ohos
  - 关键验证点：链接期符号是否能正常解析？运行时（在真机或模拟器上）Go runtime 初始化是否成功（goroutine 调度器、GC、TLS 相关初始化）？是否复现 `initial-exec TLS` 类错误（静态链接理论上应该规避，但需要实测确认）？

- [ ] **5. 记录验证结论，决定下一步路线**：
  - 若验证通过 → 继续方案A：把 netbird 的 `client/internal` 相关代码逐步接入这套交叉编译流程，之后要解决 TUN fd 传递、socket protect（鸿蒙 net-vpnextension 等价 API 待查）等平台适配问题
  - 若验证失败 → 记录具体报错和复现步骤，重新评估方案B（用 Rust/boringtun 重写）或等待 Go 官方修复 #71953 的可行性

## 后续待查项（本次验证通过后再展开）
- 鸿蒙 VPN Extension（net-vpnextension）是否有等价于 Android `VpnService.protect(fd)` 的 socket 排除 VPN 能力
- 鸿蒙后台长驻服务限制策略，对 VPN 常驻连接的影响
- netbird 主 go.mod 要求的 Go 版本，与当前装的 1.24 是否兼容（若不兼容需升级）
