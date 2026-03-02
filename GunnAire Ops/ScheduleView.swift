import SwiftUI
import SwiftData

struct ScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ServiceCall.scheduledDate)]) private var serviceCalls: [ServiceCall]
    @Query private var recurringContracts: [RecurringMaintenanceContract]
    
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showingAddCallSheet = false
    @State private var selectedCall: ServiceCall?
    
    enum ViewMode: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        var id: String { rawValue }
    }
    @State private var viewMode: ViewMode = .day
    
    var filteredCalls: [ServiceCall] {
        switch viewMode {
        case .day:
            return serviceCalls.filter { Calendar.current.isDate($0.scheduledDate, inSameDayAs: selectedDate) }
        case .week:
            let calendar = Calendar.current
            guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else { return [] }
            return serviceCalls.filter { $0.scheduledDate >= weekInterval.start && $0.scheduledDate <= weekInterval.end }
                .sorted { $0.scheduledDate < $1.scheduledDate }
        }
    }
    
    var upcomingJobs: [ServiceCall] {
        let now = Date()
        let calendar = Calendar.current
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return serviceCalls.filter { $0.scheduledDate >= now && $0.scheduledDate <= sevenDaysAhead }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }
    
    var activeRecurringContracts: [RecurringMaintenanceContract] {
        let now = Date()
        return recurringContracts.filter { $0.nextDate >= now }
    }
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                VStack(spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Upcoming Jobs (Next 7 Days):")
                                .font(.headline)
                                .foregroundColor(Color.brandGold)
                            if upcomingJobs.isEmpty {
                                Text("No upcoming jobs.")
                                    .foregroundColor(.secondary)
                                    .italic()
                            } else {
                                ForEach(upcomingJobs.prefix(3)) { job in
                                    HStack {
                                        Text(job.customer.name)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                if upcomingJobs.count > 3 {
                                    Text("And \(upcomingJobs.count - 3) more...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Divider()
                            Text("Active Recurring Contracts:")
                                .font(.headline)
                                .foregroundColor(Color.brandGold)
                            if activeRecurringContracts.isEmpty {
                                Text("No active contracts.")
                                    .foregroundColor(.secondary)
                                    .italic()
                            } else {
                                ForEach(activeRecurringContracts.prefix(3)) { contract in
                                    HStack {
                                        Text(contract.customer.name)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text("Next Due: \(contract.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                if activeRecurringContracts.count > 3 {
                                    Text("And \(activeRecurringContracts.count - 3) more...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text("Dashboard")
                            .foregroundColor(Color.brandGold)
                    }
                    .padding(.horizontal)
                    
                    DatePicker(
                        "Select Date",
                        selection: $selectedDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
                    
                    Picker("View Mode", selection: $viewMode) {
                        ForEach(ViewMode.allCases) { mode in
                            Text(mode.rawValue).bold()
                                .tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    
                    List(selection: $selectedCall) {
                        ForEach(filteredCalls) { call in
                            NavigationLink(value: call) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(call.type.rawValue.capitalized)
                                            .font(.headline)
                                            .foregroundColor(Color.brandGold)
                                        Text("- ")
                                            .foregroundColor(.primary)
                                        Text(call.customer.name)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("Time: \(call.scheduledDate.formatted(date: .omitted, time: .shortened)) - \(call.status.rawValue.capitalized)")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .onDelete(perform: deleteCalls)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Color.primaryBlack)
                }
                .navigationTitle("Schedule")
                .foregroundColor(Color.brandGold)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingAddCallSheet = true
                        } label: {
                            Label("Add Call", systemImage: "plus")
                                .bold()
                        }
                        .tint(Color.brandGold)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                            .tint(Color.brandGold)
                    }
                }
                .navigationDestination(for: ServiceCall.self) { call in
                    ServiceCallDetailView(call: call)
                        .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingAddCallSheet) {
                    AddServiceCallView(selectedDate: selectedDate)
                        .tint(Color.brandGold)
                }
            }
        }
    }
    
    private func deleteCalls(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(filteredCalls[index])
            }
        }
    }
}

#Preview {
    ScheduleView()
}
