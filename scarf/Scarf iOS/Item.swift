//
//  Item.swift
//  Scarf iOS
//
//  Created by Alan Wizemann on 4/23/26.
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
