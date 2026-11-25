# 运行时对象

对象检查只读存储字段，默认使用 `main` isolate。高效顺序是：先定位类，再一次 `find` 直接得到所需值；不要保存 VM object ID 或依赖实例顺序。

## 1. 定位精确类

```bash
dart-vm object classes --name='RealtimeRuntime'
dart-vm object classes --name='Runtime' --library='package:example/'
```

结果为空时先进入对应页面；仍为空则用 `dart-vm service list` 确认连接目标。

## 2. 查找并读取

已知字段路径时，一条 `find` 直出目标值：

```bash
dart-vm object find \
  --class RealtimeRuntime \
  --fields '_bus._transportState._name'
```

字段不确定时先看 schema：

```bash
dart-vm object find --class RealtimeRuntime --schema
```

用 `--where path=value` 精确锁定实例；可重复传入，条件按 AND 匹配。值可为未加引号字符串或 JSON 标量：

```bash
dart-vm object find \
  --class ChatViewmodel \
  --where '_userId=user-1' \
  --fields 'conversationId,_isLoadingMessages'
```

路径只支持存储字段、List/Set 下标、JSON 标量 Map key 和 Record 位置字段，例如 `_field.child`、`items[0]`、`config["host"]`。不会执行 getter、方法或表达式。

## 3. 批量读取集合

`--path` 指向 List、Set 或 Map，`--fields` 选择每行字段。`--row-limit` 是严格上限；`--match-limit` 控制匹配对象数，默认 1。

```bash
dart-vm object find \
  --class ChatViewmodel \
  --where '_userId=user-1' \
  --path 'messages._value' \
  --fields 'imMessage.messageId,imMessage.timestamp' \
  --row-limit 20
```

集合页默认 32 条；仅临时 VM ID 过期时才重定位同一对象，并以 16、8、4 条重试同一页。普通查询无需额外操作。

## 4. 执行表达式

在本地 Debug App 中使用 `object evaluate`。使用 `--class` 和 `--where` 选择唯一实例；用 `--static-class` 访问静态成员，或用 `--library-uri` 精确选择已加载的库。

```bash
dart-vm object evaluate --class DebugCounter --where 'id=preview' --expression 'count = 7'
dart-vm object evaluate --static-class DebugCounter --expression 'create()' --fields count
```

表达式可能触发目标代码的副作用，包括网络请求。运行异常或断线后先用 `object find` 确认状态，再决定是否重新执行。

## 5. 多步调试

启动 `dart-vm object session`，依次写入 JSON 行并读取每步结果。测试脚本使用
`dart-vm object session --file steps.jsonl`。下例捕获计数、跨上下文传值并显式恢复。

```jsonl
{"class":"DebugCounter","where":["id=preview"],"expression":"count","as":"old","undo":"count = previous"}
{"staticClass":"DebugCounter","expression":"create()","as":"preview"}
{"ref":"preview","scope":{"savedCount":"old"},"expression":"count = savedCount"}
{"restore":"old"}
```

- 用 `await: true` 获取 Future 的最终值，可用 `timeoutMs` 设置等待上限。超时后先检查实际状态。
- `fields` 接受存储路径数组。错误按输入行号返回，文件或管道在该步停止。交互终端可继续执行恢复。
- 保存的变量和快照仅在当前会话可用。恢复可变集合内容时，先复制要还原的数据；在关闭标准输入之前执行恢复。

## 诊断

- 默认结果紧凑；仅在排查问题时加 `--verbose`，查看 `expiredCount`、`retryCount`、`collectedCount`。
- `No loaded class`：用 `object classes` 核对名称和 `--library`。
- `has no live instances`：进入目标页面或触发初始化后重试。
- `Field ... was not found`：用 `--schema` 获取实际存储字段。
- 临时 ID 过期会自动恢复；App 重启或连接失效时重新设置 VM Service URI。
