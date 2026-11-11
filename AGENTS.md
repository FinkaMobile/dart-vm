## 目标与边界

- `dart-vm` 是本地开发者 CLI：通过 Dart VM Service 观察或控制**正在运行**的 Dart/Flutter VM。
- 网络能力只读取业务 HTTP Profile；表达式由目标 VM 执行，可能触发目标代码的副作用。对 VM 的状态修改必须是显式子命令，并在帮助中说明影响范围。
- 优先采用 Dart 官方工具链和 `vm_service`；新增第三方依赖必须有明确的协议或功能缺口，不能仅为减少少量代码引入。

## 结构

- `bin/` 只放可执行入口、全局参数和命令注册。可复用的 VM Service 连接、协议转换和数据整形放入 `lib/src/`，从 `lib/dart_vm.dart` 按需导出。
- 顶层命令按能力域分组，例如 `network`、`memory`、`cpu`；不得把领域操作平铺到根命令。
- Flutter Inspector 只读能力归入 `ui`；节点 ID 来自 `ui tree`。涉及选择节点、布局修改或重绘开关的 Inspector RPC 不得默认暴露。
- 新能力域由一个父 `Command` 承载；领域内动作使用二级子命令。根命令只保留全局选项和能力域入口。
- 保持实现紧凑。只有在命令数量、共享逻辑或测试复杂度明确增长时，才拆分命令文件或新增抽象层。

## 命令与输出

- 使用 `package:args` 的 `CommandRunner` / `Command` 处理子命令、帮助和参数错误。
- VM Service URI 是全局配置：显式 `--uri` 覆盖 `DART_VM_SERVICE_URI`；两者都未提供时，给出可操作的用法错误。
- 命令的机器可读结果输出 JSON 到标准输出；诊断和错误输出到标准错误，并使用非零退出码失败。
- 版本号变更时，必须同步 `pubspec.yaml` 与 `--version` 输出，并在构建后实际校验二者一致。

## 网络采集数据

- 网络能力只读取 `dart:io` HTTP Profile，且要清楚提示“仅记录开启后的请求”和“App 重启后数据丢失”。
- 默认不输出请求/响应 headers、cookies、认证信息或 body。读取 body 必须由用户显式传参触发。
- 新增会清空数据、改变采集开关或改变 VM 状态的操作，必须使用明确动词命名，并在命令说明中标明副作用。

## 可靠性与测试

- 连接前处理 HTTP(S) 与 WebSocket VM Service URI；通过 VM 的 `main` isolate 或第一个非系统 isolate 定位目标，并在调用能力前验证对应服务扩展可用。
- 不吞掉协议或连接错误；在 CLI 边界转换成简洁错误信息和正确退出码。
- 新命令至少覆盖帮助/参数解析和纯逻辑单测。真实 VM 的验证只用于冒烟验证，不作为自动化测试前提。
- 每次修改后执行：

  ```bash
  dart format . --set-exit-if-changed
  dart test
  dart analyze
  ```

## 构建与产物

- 本地开发用 `dart run bin/dart_vm.dart ...`。
- 本机二进制固定构建到 `build/dart-vm`：`mkdir -p build && dart compile exe bin/dart_vm.dart -o build/dart-vm`。
- 正式版本由 `v*` Tag 触发 GitHub Actions，在目标系统原生编译并发布 ZIP 与 SHA-256 校验文件。
- macOS / Linux 安装脚本将 Release 二进制安装到 `~/.local/bin/dart-vm`；Windows 安装到 `%LOCALAPPDATA%\dart-vm\dart-vm.exe`。安装和升级不得修改已有 VM Service URI 配置。
- `upgrade --check` 只读；`upgrade` 必须验证对应 Release 的 SHA-256，并且仅允许替换名为 `dart-vm` / `dart-vm.exe` 的已编译可执行文件，严禁覆盖 Dart SDK。
- 构建输出属于本地产物，不提交，也不作为源码事实源。
- 不引入 Makefile 或其他任务编排工具；保持使用 Dart 原生命令。
