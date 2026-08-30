import Foundation

enum AppleMapsDirections {
    /// Opens Apple Maps with driving directions from the user's current location.
    /// GunnAire Ops never reads or stores the device location for this handoff.
    static func destinationURL(address: String?) -> URL? {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: address),
            URLQueryItem(name: "dirflg", value: "d")
        ]
        return components.url
    }

    /// Prefers the immutable job-site snapshot, but still supports older jobs
    /// that only have an address on the customer record.
    static func destinationURL(siteAddress: String?, customerAddress: String?) -> URL? {
        destinationURL(address: siteAddress) ?? destinationURL(address: customerAddress)
    }
}

enum TechnicianRoutePolicy {
    /// Selects the technician's next actionable stop without changing dispatch
    /// order or representing the result as live-traffic route optimization.
    /// An already-en-route visit remains the active commitment; otherwise the
    /// earliest open, navigable visit scheduled for today is selected.
    static func nextNavigableStop(
        from calls: [ServiceCall],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ServiceCall? {
        calls
            .filter { call in
                calendar.isDate(call.scheduledDate, inSameDayAs: now) &&
                    call.status != .completed &&
                    call.status != .invoiced &&
                    call.status != .cancelled &&
                    call.technicianJobPresence != .onSite &&
                    call.technicianJobPresence != .working &&
                    AppleMapsDirections.destinationURL(
                        siteAddress: call.siteAddress,
                        customerAddress: call.customer?.address
                    ) != nil
            }
            .sorted { lhs, rhs in
                let lhsIsEnRoute = lhs.technicianJobPresence == .enRoute
                let rhsIsEnRoute = rhs.technicianJobPresence == .enRoute
                if lhsIsEnRoute != rhsIsEnRoute {
                    return lhsIsEnRoute && !rhsIsEnRoute
                }
                if lhs.scheduledDate != rhs.scheduledDate {
                    return lhs.scheduledDate < rhs.scheduledDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }
}
