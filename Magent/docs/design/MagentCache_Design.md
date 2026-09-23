# MagentCache 产品设计

更新日期：2026-09-22。

状态：目标设计，当前源码尚未完成迁移。
约束来源：[W-TinyLFU Cache SPEC](../W-TinyLFU_CACHE_SPCE.md)；
集成边界：[Magent 架构](../ARCHITECTURE.md)。

## Context

`MagentCache<Value: Sendable>` 是 Magent 包内的本地内存缓存组件，使用 String 作为 key。
主要用于 `MagentCore` 缓存 `Decision`，减少同一运行周期内重复的规则匹配。

缓存负责容量、有效期、同步加载、失效和移除通知；调用方负责 key 的业务含义及规范化、
值的计算和错误处理。W-TinyLFU 是内部策略，其算法与验收约束由 SPEC 定义。
MagentCache 不属于应用侧 public API，也不拥有网络连接、规则配置或服务生命周期。

## Contract

配置在创建时确定：`capacity` 为最大驻留条目数，`expiration` 默认为 `never`，
`onRemoval(key, value, reason)` 为可选的非抛错通知。非法配置使创建失败。

有效期支持 `never`、`afterWrite(Duration)` 和 `afterAccess(Duration)`：
写入或替换重设期限，`afterAccess` 还在有效读取命中时续期；`contains` 不续期。

以下为目标操作及其业务语义，完整约束以 SPEC 为准：

| 操作 | 契约 |
|---|---|
| `get(key)` | 返回有效值，缺失或过期返回 nil |
| `contains(key)` | 判断值是否有效，不改变访问热度 |
| `getOrLoad(key, loader)` | 命中直接返回；缺失时同步执行 loader，再按当前状态决定返回值及是否缓存 |
| `put(key, value)` | 插入或替换；完成后驻留数量不超过 capacity，不承诺该值一定被保留 |
| `invalidate(key)` | 删除该 key，并阻止此前同 key 的加载结果重新写入 |
| `removeAll()` | 清空条目及访问历史，并阻止此前所有加载结果重新写入 |
| `estimatedSize()` | 返回驻留条目数，可能包含尚未清理的过期项 |
| `cleanUp()` | 清理在本次时间判断点已过期的全部条目 |
| `close()` | 终止实例并清空条目，阻止旧加载回填；可重复调用 |

操作支持并发调用。移除通知携带实际移除的 key、value 和原因，替换也通知旧值；
同一驻留值版本只通知一次。通知不表示调用方已停止使用该值。

## Core Logic

1. **创建与归属**：每个 `MagentCore` 运行周期拥有独立的 `MagentCache<Decision>`。
   Core 定义业务 key，只缓存决策结果，后续节点与 Wire 选择仍由 Core 负责。
2. **路由查询**：每次查询使用一次 `getOrLoad`。缺失时，loader 执行当前 Core 的本地规则匹配，
   未匹配则返回配置的默认决策；loader 不执行网络 I/O。
3. **加载完成**：缓存仍运行且已有有效值时，返回当前值；没有有效值时，仅在缓存仍运行且加载未被失效时尝试缓存结果。
   已失效或已关闭的加载仍可向原调用者返回自己的结果，但不再回填。成功缓存的有效期从写入时起算。
4. **更新与失效**：调用方通过 `put` 更新值，通过 `invalidate` 或 `removeAll` 撤销缓存结果。
   过期值不能作为命中返回，也不能因访问而复活；新条目写入前先回收已过期条目。
5. **运行周期切换**：restart 创建新的 Core 和缓存。拥有者停止向旧运行周期提交新请求，
   完成其需要等待的处理后关闭旧缓存；缓存关闭不代替连接关闭或等待业务 loader。

## Corners

| 场景 | 业务边界 |
|---|---|
| `capacity = 0` | 禁用存储；运行中的 `getOrLoad` 仍执行 loader，其结果不产生移除通知 |
| 非法容量或 TTL | 负容量、非正或小于支持精度的 TTL、数值不可表示时创建失败；精度与范围见 SPEC |
| 同 key 并发缺失 | 允许重复执行 loader，不保证合并请求；loader 失败原样抛错，不缓存失败结果 |
| 加载期间失效 | 即使 key 当前不存在，invalidate 仍阻止旧加载回填；需要禁止旧结果返回的业务自行检查版本或取消状态 |
| 移除通知重入 | 回调可以再次调用缓存，也可能并发执行；通知顺序不保证等于状态变更顺序，removeAll 后可被回调重新写入 |
| 已关闭实例 | get 返回 nil、contains 返回 false、size 为 0；写入、失效和清理无效，新 getOrLoad 报 CacheClosed 且不执行 loader |
| 关闭时仍有加载 | 已开始的 loader 不被取消，也不由 close 等待；其结果不能重新进入缓存 |
| 业务 key 与 value | 使用 Swift String 相等语义；地址类型、域名规范化及业务版本由 Core 处理；可变引用值的使用安全由调用方负责 |
| Core 错误处理 | 配置错误和意外的 CacheClosed 进入已有上层错误路径，不解释为规则未命中或默认直连 |
