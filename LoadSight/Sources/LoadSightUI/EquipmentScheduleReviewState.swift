import LoadSightKit

/// Presentation state is separate from disposable extraction results.
@MainActor struct EquipmentScheduleReviewState {
    var request: EquipmentScheduleRequest?
    var selected: DrawingReviewSelection<EquipmentScheduleRow>?

    mutating func invalidateResults() {
        request = nil
        // Do not clear the sheet binding: a nested RFI may contain unsaved text.
        // Keep its original identity/snapshot until explicit dismissal. Its
        // captured DrawingReviewSession still rejects stale-source writes.
    }
}
