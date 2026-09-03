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

## 诊断

- 默认结果紧凑；仅在排查问题时加 `--verbose`，查看 `expiredCount`、`retryCount`、`collectedCount`。
- `No loaded class`：用 `object classes` 核对名称和 `--library`。
- `has no live instances`：进入目标页面或触发初始化后重试。
- `Field ... was not found`：用 `--schema` 获取实际存储字段。
- 临时 ID 过期会自动恢复；App 重启或连接失效时重新设置 VM Service URI。
