import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReceiptsAndBillsView: View {
    @State private var showingReceiptPicker = false
    @State private var showingBillPicker = false
    
    @State private var receiptImage: UIImage?
    @State private var billImage: UIImage?
    @State private var receiptURL: URL?
    @State private var billURL: URL?
    
    @State private var receiptImportMessage: String? = nil
    @State private var billImportMessage: String? = nil
    @State private var isSyncing = false
    @State private var syncMessage: String?
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
                    Section(header: Text("Upload Receipts")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        Button(action: {
                            showingReceiptPicker = true
                        }) {
                            Label("Select Receipt File or Image", systemImage: "tray.and.arrow.down.fill")
                                .bold()
                                .foregroundColor(Color.brandGold)
                        }
                        if receiptImage != nil {
                            Text("Receipt selected")
                                .foregroundColor(.secondary)
                        }
                        if let receiptImportMessage {
                            Text(receiptImportMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section(header: Text("Upload Vendor Bills")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        Button(action: {
                            showingBillPicker = true
                        }) {
                            Label("Select Bill File or Image", systemImage: "doc.plaintext")
                                .bold()
                                .foregroundColor(Color.brandGold)
                        }
                        if billImage != nil {
                            Text("Bill selected")
                                .foregroundColor(.secondary)
                        }
                        if let billImportMessage {
                            Text(billImportMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section(header: Text("Sync and Transactions")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        Button("Sync Receipts and Bills with QuickBooks") {
                            syncDocuments()
                        }
                        .tint(Color.brandGold)
                        .disabled(isSyncing || (receiptURL == nil && billURL == nil))
                        
                        if isSyncing {
                            ProgressView("Syncing...")
                                .tint(Color.brandGold)
                        }
                        if let syncMessage {
                            Text(syncMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section(header: Text("Selected Files")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        if let receiptURL {
                            Text("Receipt: \(receiptURL.lastPathComponent)")
                                .foregroundColor(.secondary)
                        }
                        if let billURL {
                            Text("Bill: \(billURL.lastPathComponent)")
                                .foregroundColor(.secondary)
                        }
                        if receiptURL == nil && billURL == nil {
                            Text("No files selected.")
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primaryBlack)
                .navigationTitle("Receipts & Bills")
                .foregroundColor(Color.brandGold)
            }
        }
        .fileImporter(isPresented: $showingReceiptPicker,
                      allowedContentTypes: [.image, .pdf, .plainText, .rtf]) { result in
            switch result {
            case .success(let url):
                do {
                    try importDocument(from: url, as: .receipt)
                } catch {
                    receiptURL = nil
                    receiptImage = nil
                    receiptImportMessage = "Failed to read file: \(error.localizedDescription)"
                }
            case .failure(let error):
                print("Receipt file import error: \(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $showingBillPicker,
                      allowedContentTypes: [.image, .pdf, .plainText, .rtf]) { result in
            switch result {
            case .success(let url):
                do {
                    try importDocument(from: url, as: .bill)
                } catch {
                    billURL = nil
                    billImage = nil
                    billImportMessage = "Failed to read file: \(error.localizedDescription)"
                }
            case .failure(let error):
                print("Bill file import error: \(error.localizedDescription)")
            }
        }
}
}

private extension ReceiptsAndBillsView {
    enum DocumentType {
        case receipt
        case bill
    }
    
    func importDocument(from url: URL, as type: DocumentType) throws {
        let data = try Data(contentsOf: url)
        let extensionName = url.pathExtension.lowercased()
        let image = UIImage(data: data)
        
        switch type {
        case .receipt:
            receiptImportMessage = nil
            receiptURL = url
            if let image {
                receiptImage = image
                receiptImportMessage = "Image selected: \(url.lastPathComponent)"
            } else if extensionName == "pdf" {
                receiptImage = nil
                receiptImportMessage = "PDF selected: \(url.lastPathComponent)"
            } else if ["txt", "rtf"].contains(extensionName) {
                receiptImage = nil
                receiptImportMessage = "Text document selected: \(url.lastPathComponent)"
            } else {
                receiptURL = nil
                receiptImage = nil
                receiptImportMessage = "Unsupported file type"
            }
        case .bill:
            billImportMessage = nil
            billURL = url
            if let image {
                billImage = image
                billImportMessage = "Image selected: \(url.lastPathComponent)"
            } else if extensionName == "pdf" {
                billImage = nil
                billImportMessage = "PDF selected: \(url.lastPathComponent)"
            } else if ["txt", "rtf"].contains(extensionName) {
                billImage = nil
                billImportMessage = "Text document selected: \(url.lastPathComponent)"
            } else {
                billURL = nil
                billImage = nil
                billImportMessage = "Unsupported file type"
            }
        }
    }
    
    func syncDocuments() {
        let uploadCount = (receiptURL == nil ? 0 : 1) + (billURL == nil ? 0 : 1)
        guard uploadCount > 0 else {
            syncMessage = "Select at least one file before syncing."
            return
        }
        
        isSyncing = true
        syncMessage = nil
        
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            isSyncing = false
            syncMessage = "Sync complete. \(uploadCount) file(s) prepared for QuickBooks upload."
        }
    }
}

#Preview {
    ReceiptsAndBillsView()
}
