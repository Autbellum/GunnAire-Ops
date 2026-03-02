import SwiftUI

struct QuickBooksManagementView: View {
    @StateObject private var qbAPI = QBStubAPIClient()
    
    @State private var showingNewInvoiceSheet = false
    @State private var showingNewBillSheet = false
    @State private var showingNewVendorSheet = false
    @State private var showingNewPaymentSheet = false
    
    @State private var syncStatusMessage: String = ""
    @State private var isSyncing = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
                    Section(header: Text("Invoices").foregroundColor(Color.brandGold)) {
                        if qbAPI.isLoadingInvoices {
                            ProgressView()
                                .tint(Color.brandGold)
                        } else if let error = qbAPI.invoiceError {
                            Text("Error loading invoices: \(error.localizedDescription)")
                                .foregroundColor(.red)
                                .italic()
                        } else if qbAPI.invoices.isEmpty {
                            Text("No invoices found.")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(qbAPI.invoices, id: \.Id) { invoice in
                                VStack(alignment: .leading) {
                                    Text("Invoice #: \(invoice.DocNumber ?? "N/A")")
                                        .font(.headline)
                                        .foregroundColor(Color.brandGold)
                                    if let customerName = invoice.CustomerRef?.name {
                                        Text("Customer: \(customerName)")
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                    }
                                    if let totalAmt = invoice.TotalAmt {
                                        Text(String(format: "Total: $%.2f", totalAmt))
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                    }
                                    if let txnDate = invoice.TxnDate {
                                        Text("Date: \(txnDate)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        Button("Create New Invoice") {
                            showingNewInvoiceSheet = true
                        }
                        .tint(Color.brandGold)
                    }
                    
                    Section(header: Text("Bills").foregroundColor(Color.brandGold)) {
                        Text("Bills management coming soon.")
                            .foregroundColor(.secondary)
                            .italic()
                        Button("Create New Bill") {
                            showingNewBillSheet = true
                        }
                        .tint(Color.brandGold)
                    }
                    
                    Section(header: Text("Vendors").foregroundColor(Color.brandGold)) {
                        Text("Vendor management coming soon.")
                            .foregroundColor(.secondary)
                            .italic()
                        Button("Add New Vendor") {
                            showingNewVendorSheet = true
                        }
                        .tint(Color.brandGold)
                    }
                    
                    Section(header: Text("Payments").foregroundColor(Color.brandGold)) {
                        Text("Payments management coming soon.")
                            .foregroundColor(.secondary)
                            .italic()
                        Button("Add New Payment") {
                            showingNewPaymentSheet = true
                        }
                        .tint(Color.brandGold)
                    }
                    
                    Section(header: Text("Sync Status").foregroundColor(Color.brandGold)) {
                        if isSyncing {
                            ProgressView()
                        }
                        Text(syncStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Section {
                        Button("Sync All Transactions with QuickBooks") {
                            syncAllTransactions()
                        }
                        .tint(Color.brandGold)
                        .disabled(isSyncing)
                    }
                    
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primaryBlack)
                .navigationTitle("QuickBooks Management")
                .foregroundColor(Color.brandGold)
                .sheet(isPresented: $showingNewInvoiceSheet) {
                    NewInvoiceView(dismiss: {
                        showingNewInvoiceSheet = false
                        qbAPI.fetchInvoices()
                    })
                    .environmentObject(qbAPI)
                    .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewBillSheet) {
                    NewBillView(dismiss: { showingNewBillSheet = false })
                        .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewVendorSheet) {
                    NewVendorView(dismiss: { showingNewVendorSheet = false })
                        .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingNewPaymentSheet) {
                    NewPaymentView(dismiss: { showingNewPaymentSheet = false })
                        .tint(Color.brandGold)
                }
                .onChange(of: qbAPI.isLoadingInvoices) { _, newValue in
                    if newValue == false {
                        if isSyncing {
                            syncStatusMessage = "Sync complete."
                            isSyncing = false
                        }
                    } else {
                        if isSyncing == false {
                            syncStatusMessage = "Loading invoices..."
                        }
                    }
                }
                .onAppear {
                    qbAPI.fetchInvoices()
                }
            }
        }
    }
    
    private func syncAllTransactions() {
        isSyncing = true
        syncStatusMessage = "Syncing transactions with QuickBooks..."
        errorMessage = nil
        qbAPI.fetchInvoices()
    }
}

#Preview {
    QuickBooksManagementView()
}
