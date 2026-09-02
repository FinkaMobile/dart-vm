# 运行时对象检查

动态查找所选 isolate 中已加载的 Dart 类和存活对象，并读取对象的存储字段或集合成员。
省略 `--isolate` 时优先使用 `main` isolate。

## 查找类

先按区分大小写的名称片段搜索类：

```bash
dart-vm object classes --name="CacheManager"
```

同名类来自不同 library 时，使用返回的 library URI 片段缩小范围：

```bash
dart-vm object classes \
  --name="CacheManager" \
  --library="package:example/"
```

搜索结果为空时，先进入会初始化该功能的 App 页面，再重新查询。必要时运行
`dart-vm service list`，确认当前连接的是预期进程。

## 查找实例

使用完整且区分大小写的类名查询实例：

```bash
dart-vm object instances --class="CacheManager"
```

`totalCount` 表示实例总数，`returnedCount` 受 `--limit` 控制。VM 不保证实例顺序稳定，
不要跨命令保存数组下标；使用返回的对象 ID 继续检查。

## 读取对象

类只有一个存活实例时，直接读取浅层字段：

```bash
dart-vm object get --class="CacheManager"
```

一步读取嵌套状态：

```bash
dart-vm object get \
  --class="CacheManager" \
  --path="_client._status._name"
```

类有多个实例时，先运行 `object instances`，再使用结果里的对象 ID：

```bash
dart-vm object get \
  --id="objects/123/0" \
  --path="items[0].id"
```

路径支持以下只读访问：

- `_field.child`：对象的存储字段，包括私有字段。
- `items[0]`：List 下标。
- `config["host"]`：String、数字、bool 或 null 类型的 Map key。
- `record[0]`：Record 位置字段。

命令不会执行 getter、方法或任意 Dart 表达式。最终值是集合时，使用 `--limit` 控制浅层
结果最多包含多少项。

## 诊断

- `No loaded class`：运行 `object classes --name <名称片段>` 检查真实类名和 library URI。
- `has no live instances`：进入相关页面或触发初始化后重试。
- `has ... live instances`：运行 `object instances`，再通过 `object get --id` 指定实例。
- `Field ... was not found`：去掉路径或只保留父路径，查看实际字段名。
- `Object ... is unavailable`：对象 ID 已因 GC、Hot Restart 或 App 重启失效，重新查询实例。
- `No isolate matches`：省略 `--isolate` 使用 main，或根据错误列出的 isolate 名称和 ID 选择。
