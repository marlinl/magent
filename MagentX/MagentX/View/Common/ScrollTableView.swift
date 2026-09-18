//
//  ScrollTableView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Reuses a native SwiftUI table with a bounded SwiftData query.
//

import SwiftData
import SwiftUI

/// 持有受限 SwiftData 查询，并将其结果直接交给原生 `Table`。
@MainActor
struct ScrollTableView<Model, Columns, EmptyContent>: View
where
  Model: PersistentModel & Identifiable,
  Columns: TableColumnContent,
  EmptyContent: View,
  Columns.TableRowValue == Model
{
  @Query private var models: [Model]
  @Binding private var selection: Set<Model.ID>

  private let emptyContent: () -> EmptyContent
  private let columns: () -> Columns

  /// 以业务页提供的筛选和排序创建有限模型查询。
  init(
    selection: Binding<Set<Model.ID>>,
    descriptor: FetchDescriptor<Model>,
    maximumCachedModelCount: Int,
    @ViewBuilder emptyContent: @escaping () -> EmptyContent,
    @TableColumnBuilder<Model, Never> columns: @escaping () -> Columns
  ) {
    precondition(maximumCachedModelCount > 0, "maximumCachedModelCount must be positive")

    var descriptor = descriptor
    descriptor.fetchLimit = maximumCachedModelCount
    _models = Query(descriptor)
    _selection = selection
    self.emptyContent = emptyContent
    self.columns = columns
  }

  var body: some View {
    Group {
      if models.isEmpty {
        emptyContent()
      } else {
        Table(models, selection: $selection, columns: columns)
      }
    }
  }
}
