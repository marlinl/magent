import Foundation
import SwiftData

/// 仅供 ScrollTableView 测试使用的故障开关；通过真实 DataStore 协议返回失败。
final class ScrollTableFaults: @unchecked Sendable, Hashable {
  private let lock = NSLock()
  private var mode = "none"

  /// 设置下一次测试所需的失败类型，关闭时不影响真实内存存储。
  func set(_ mode: String) { lock.withLock { self.mode = mode } }

  /// 按故障类型抛出确定错误；首批故障只发生一次，便于验证显式重试。
  func check(_ operation: String, limit: Int? = nil, offset: Int? = nil) throws {
    let shouldFail = lock.withLock {
      if mode == "initial-query", operation == "query" {
        mode = "none"
        return true
      }
      return mode == operation && (operation == "count" || (limit ?? 0) > 100 || (offset ?? 0) > 0)
    }
    if shouldFail {
      throw NSError(
        domain: "ScrollTableUITest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "测试注入的查询失败"])
    }
  }

  /// 不同故障开关代表不同的测试存储配置。
  static func == (lhs: ScrollTableFaults, rhs: ScrollTableFaults) -> Bool { lhs === rhs }

  /// 以对象身份计算哈希，故障状态改变不会改变容器配置身份。
  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// 故障用例使用的内存快照配置，不在产品代码中加入测试开关。
struct ScrollTableFaultConfiguration: DataStoreConfiguration {
  typealias Store = ScrollTableFaultStore
  let name = "ScrollTableFaults"
  var schema: Schema?
  let faults: ScrollTableFaults

  /// 宿主显式提供测试模型 schema，不支持缺失模型定义的配置。
  func validate() throws {
    if schema == nil { throw DataStoreError.unsupportedFeature }
  }
}

/// 仅故障用例使用的 SwiftData 快照存储；正常用例仍使用系统 DefaultStore。
///
/// 只实现故障用例使用的 id 正序查询；普通筛选与排序由系统 DefaultStore 用例覆盖。
final class ScrollTableFaultStore: DataStore {
  typealias Configuration = ScrollTableFaultConfiguration
  typealias Snapshot = DefaultSnapshot
  let configuration: Configuration
  let identifier = UUID().uuidString
  let schema: Schema
  private var snapshots: [PersistentIdentifier: Snapshot] = [:]
  private var rowNumbers: [PersistentIdentifier: Int] = [:]

  /// 标准快照使用模型属性名编码，这里只解码故障用例所需的唯一排序字段。
  private struct RowNumber: Decodable { let id: Int }

  /// 接收独立测试配置，不创建默认存储内部依赖的持久化栈。
  init(_ configuration: Configuration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
    try configuration.validate()
    self.configuration = configuration
    schema = configuration.schema!
  }

  /// 在真实 @Query 读取边界注入故障，成功时返回 SwiftData 标准快照。
  func fetch<T>(_ request: DataStoreFetchRequest<T>) throws -> DataStoreFetchResult<T, Snapshot> {
    try configuration.faults.check(
      "query", limit: request.descriptor.fetchLimit, offset: request.descriptor.fetchOffset)
    if request.descriptor.predicate != nil { throw DataStoreError.preferInMemoryFilter }
    let values = snapshots.values.sorted {
      rowNumbers[$0.persistentIdentifier, default: 0]
        < rowNumbers[$1.persistentIdentifier, default: 0]
    }
    .dropFirst(request.descriptor.fetchOffset ?? 0)
    .prefix(request.descriptor.fetchLimit ?? snapshots.count)
    return DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: Array(values))
  }

  /// 故障用例只查询未筛选的测试集合，计数失败保持原始错误。
  func fetchCount<T>(_ request: DataStoreFetchRequest<T>) throws -> Int {
    try configuration.faults.check("count")
    return snapshots.count
  }

  /// 沿用相同查询语义返回标识。
  func fetchIdentifiers<T>(_ request: DataStoreFetchRequest<T>) throws -> [PersistentIdentifier] {
    try fetch(request).fetchedSnapshots.map(\.persistentIdentifier)
  }

  /// 为插入快照分配永久标识，并应用测试上下文的更新与删除。
  func save(_ request: DataStoreSaveChangesRequest<Snapshot>) throws
    -> DataStoreSaveChangesResult<Snapshot>
  {
    var remapped: [PersistentIdentifier: PersistentIdentifier] = [:]
    for snapshot in request.inserted {
      let permanent = try PersistentIdentifier.identifier(
        for: identifier, entityName: snapshot.persistentIdentifier.entityName,
        primaryKey: UUID().uuidString)
      remapped[snapshot.persistentIdentifier] = permanent
      snapshots[permanent] = snapshot.copy(persistentIdentifier: permanent)
      rowNumbers[permanent] = try JSONDecoder().decode(
        RowNumber.self, from: JSONEncoder().encode(snapshot)
      ).id
    }
    for snapshot in request.updated {
      snapshots[snapshot.persistentIdentifier] = snapshot
      rowNumbers[snapshot.persistentIdentifier] = try JSONDecoder().decode(
        RowNumber.self, from: JSONEncoder().encode(snapshot)
      ).id
    }
    for snapshot in request.deleted {
      snapshots.removeValue(forKey: snapshot.persistentIdentifier)
      rowNumbers.removeValue(forKey: snapshot.persistentIdentifier)
    }
    return DataStoreSaveChangesResult(for: identifier, remappedIdentifiers: remapped)
  }

  /// 返回已经保存的快照，供上下文解析永久标识。
  func cachedSnapshots(for identifiers: [PersistentIdentifier], editingState: EditingState) throws
    -> [PersistentIdentifier: Snapshot]
  {
    snapshots.filter { identifiers.contains($0.key) }
  }

  /// 此内存测试存储没有额外的上下文资源。
  func initializeState(for editingState: EditingState) {}

  /// 上下文销毁不影响同一容器的内存快照。
  func invalidateState(for editingState: EditingState) {}

  /// 清空本次测试的全部快照。
  func erase() throws {
    snapshots.removeAll()
    rowNumbers.removeAll()
  }
}
