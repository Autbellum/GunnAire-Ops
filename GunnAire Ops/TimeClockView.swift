import SwiftUI
import SwiftData

struct TimeClockView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var entries: [TimeEntry]

    private var signedInEmail: String {
        googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail") ?? "testing@gunnaire.com"
    }

    private var isOwnerAccount: Bool {
        AppAccess.isPrimaryAdmin(signedInEmail)
    }

    private var userEntries: [TimeEntry] {
        entries.filter { $0.userEmail.caseInsensitiveCompare(signedInEmail) == .orderedSame }
    }

    private var openEntry: TimeEntry? {
        userEntries.first { $0.isOpen }
    }

    var body: some View {
        NavigationStack {
            List {
                if isOwnerAccount {
                    Section("Owner Account") {
                        Text("Owner account signed in.")
                            .font(.headline)
                        Text("Clock in/out is not required for Eric Gunn.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section("Current Status") {
                        if let openEntry {
                            Text("Clocked in since \(openEntry.clockIn.formatted(date: .abbreviated, time: .shortened))")
                            if let serviceCall = openEntry.serviceCall {
                                Text("Job: \(serviceCall.customer.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button("Clock Out") {
                                openEntry.clockOut = Date()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                        } else {
                            Text("You are clocked out.")
                                .foregroundColor(.secondary)
                            Button("Clock In") {
                                modelContext.insert(TimeEntry(userEmail: signedInEmail))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            Text("Job selection is optional for now and will be available for future job-level time tracking.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if !isOwnerAccount {
                    Section("Recent Time Entries") {
                        if userEntries.isEmpty {
                            Text("No time entries yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(userEntries.prefix(20)) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.clockIn.formatted(date: .abbreviated, time: .shortened))
                                        .font(.headline)
                                    Text(entry.clockOut.map { "Out: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Open shift")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let serviceCall = entry.serviceCall {
                                        Text("Job: \(serviceCall.customer.name)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Time Clock")
        }
    }
}

#Preview {
    TimeClockView()
}
