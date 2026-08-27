//
//  Item.swift
//  iMagent
//
//  Created by MarlinL on 2026/4/7.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date

    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
