//
//  Item.swift
//  ProjectAmbrosia
//
//  Created by miniman on 2026-03-09.
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
