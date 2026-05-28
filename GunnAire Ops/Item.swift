//
//  Item.swift
//  GunnAire Ops
//
//  Created by Eric Gunn on 2/23/26.
//

import Foundation
import SwiftData

enum CatalogItemType: String, Codable, CaseIterable, Identifiable {
    case service = "Service"
    case nonInventory = "NonInventory"

    var id: String { rawValue }
}

@Model
final class Item {
    @Attribute(.unique) var id: UUID = UUID()
    var quickBooksID: String?
    var name: String = ""
    var itemTypeRawValue: String = CatalogItemType.service.rawValue
    var unitPrice: Double = 0
    var purchaseCost: Double?
    var isTaxable: Bool = false
    var itemDescription: String?
    var sku: String?
    var preferredVendorName: String?
    var preferredVendorQuickBooksID: String?
    var vendorPartNumber: String?
    var purchaseURL: String?
    var purchaseDescription: String?
    var createdAt: Date = Date()
    var timestamp: Date = Date()

    init(
        id: UUID = UUID(),
        quickBooksID: String? = nil,
        name: String,
        itemType: CatalogItemType = .service,
        unitPrice: Double,
        purchaseCost: Double? = nil,
        isTaxable: Bool = false,
        itemDescription: String? = nil,
        sku: String? = nil,
        preferredVendorName: String? = nil,
        preferredVendorQuickBooksID: String? = nil,
        vendorPartNumber: String? = nil,
        purchaseURL: String? = nil,
        purchaseDescription: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.itemTypeRawValue = itemType.rawValue
        self.unitPrice = unitPrice
        self.purchaseCost = purchaseCost
        self.isTaxable = isTaxable
        self.itemDescription = itemDescription
        self.sku = sku
        self.preferredVendorName = preferredVendorName
        self.preferredVendorQuickBooksID = preferredVendorQuickBooksID
        self.vendorPartNumber = vendorPartNumber
        self.purchaseURL = purchaseURL
        self.purchaseDescription = purchaseDescription
        self.createdAt = createdAt
        self.timestamp = createdAt
    }

    var itemType: CatalogItemType {
        get { CatalogItemType(rawValue: itemTypeRawValue) ?? .service }
        set { itemTypeRawValue = newValue.rawValue }
    }
}
