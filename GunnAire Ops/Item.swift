//
//  Item.swift
//  GunnAire Ops
//
//  Created by Eric Gunn on 2/23/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    @Attribute(.unique) var id: UUID = UUID()
    var quickBooksID: String?
    var name: String = ""
    var unitPrice: Double = 0
    var itemDescription: String?
    var createdAt: Date = Date()
    var timestamp: Date = Date()

    init(id: UUID = UUID(), quickBooksID: String? = nil, name: String, unitPrice: Double, itemDescription: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.unitPrice = unitPrice
        self.itemDescription = itemDescription
        self.createdAt = createdAt
        self.timestamp = createdAt
    }
}
