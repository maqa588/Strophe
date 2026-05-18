//
//  Item.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
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
