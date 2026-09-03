---
name: dart-vm-inspect
description: 使用 `dart-vm` CLI 发现本机运行中的 Dart 或 Flutter VM Service，查看 HTTP Profile 请求及 body，动态查找类和对象，检查 Flutter Widget 树、属性、布局和截图，并调用项目已注册的 VM Service extension。
---

# 使用 dart-vm 检查运行中的应用

`dart-vm` 用于发现本机 VM Service 会话，并检查运行中的 Dart 或 Flutter 应用。

## 连接应用

1. 运行 `dart-vm service list`，根据 `deviceName`、`packageName` 和 `pid` 选择目标。
2. 默认运行 `dart-vm config uri set "<vm-service-uri>"` 保存目标，后续命令直接调用。仅多个会话同时运行时，使用 `dart-vm --uri "<vm-service-uri>" <command>` 单独指定目标。

## 检查应用

- 查看 HTTP Profile 请求时，读取 [references/network.md](references/network.md)。
- 检查运行时对象时，先用 `object classes` 定位精确类，再用 `object find` 筛选、读取或提取集合字段；读取 [references/object.md](references/object.md)。
- 查看 Widget 树、属性、布局或截图时，读取 [references/ui.md](references/ui.md)。
- 调用已注册的 VM Service extension 时，读取 [references/extension.md](references/extension.md)。

## 输出结果

原样返回命令输出，不进行预处理。
