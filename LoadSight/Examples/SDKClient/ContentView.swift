import SwiftUI
import LoadSightKit
@MainActor public struct SDKContentView: View {
    private let project: ProjectDocument
    private let service: any LoadSightServicing
    @State private var status = "Ready to review the recorded estimate."
    @State private var operation: LoadSightOperation<BidReview>?
    @State private var monitor: Task<Void, Never>?
    @State private var generation: UUID?
    public init(project: ProjectDocument, service: any LoadSightServicing = LocalLoadSightService()) {
        self.project = project; self.service = service
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project.name).font(.headline)
            Text(status).accessibilityIdentifier("SDKReviewStatus")
            Button("Review estimate") { start() }.disabled(operation != nil)
            Button("Cancel review") { cancel() }.disabled(operation == nil)
            Text("Recorded evidence only; no external publication.").font(.caption)
        }.padding().onDisappear { cancel() }
    }
    private func start() {
        let snapshot = project, service = service, id = UUID()
        generation = id
        let job = LoadSightOperation { progress in
            try await service.reviewEstimate(snapshot, asOf: Date(), progress: progress)
        }
        operation = job
        monitor = Task {
            let observer = Task {
                for await event in job.progress {
                    guard !Task.isCancelled, generation == id else { return }
                    status = event.stage
                }
            }
            defer { observer.cancel() }
            do {
                let review = try await job.result
                guard generation == id, !Task.isCancelled else { return }
                generation = nil
                status = "\(review.pricedCount) priced rows; \(review.blockers.count) review holds."
            } catch {
                guard generation == id else { return }
                generation = nil
                status = error is CancellationError ? "Review cancelled." : error.localizedDescription
            }
            operation = nil; monitor = nil
        }
    }
    private func cancel() {
        let wasRunning = operation != nil
        generation = nil; operation?.cancel(); monitor?.cancel()
        operation = nil; monitor = nil
        if wasRunning { status = "Review cancelled." }
    }
}
