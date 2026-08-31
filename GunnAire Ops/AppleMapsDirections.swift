import Foundation
import MapKit

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

    /// Opens the exact drive between two scheduled stops. Unlike
    /// `destinationURL(address:)`, this handoff never substitutes the device's
    /// current location for either endpoint.
    static func routeURL(sourceAddress: String?, destinationAddress: String?) -> URL? {
        guard let sourceAddress = normalizedAddress(sourceAddress),
              let destinationAddress = normalizedAddress(destinationAddress) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "saddr", value: sourceAddress),
            URLQueryItem(name: "daddr", value: destinationAddress),
            URLQueryItem(name: "dirflg", value: "d")
        ]
        return components.url
    }

    fileprivate static func normalizedAddress(_ address: String?) -> String? {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return nil
        }
        return address
    }
}

enum TechnicianRouteLegReadiness: Equatable, Sendable {
    case ready
    case sameAddress
    case missingOriginAddress
    case missingDestinationAddress
    case missingBothAddresses
}

struct TechnicianRouteLegSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let originCallID: UUID
    let destinationCallID: UUID
    let originTitle: String
    let destinationTitle: String
    let originAddress: String?
    let destinationAddress: String?
    let plannedDepartureDate: Date
    let scheduledGapMinutes: Int
    let readiness: TechnicianRouteLegReadiness
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

    /// Builds one informational route leg for every pair of adjacent
    /// active or historical appointments. Cancelled work is not a scheduled
    /// stop. A missing-address appointment is intentionally retained instead
    /// of being skipped, so the result can never imply a different dispatch
    /// order.
    static func appointmentTravelLegs(from calls: [ServiceCall]) -> [TechnicianRouteLegSnapshot] {
        let orderedCalls = calls
            .filter { $0.status != .cancelled }
            .sorted { lhs, rhs in
                if lhs.scheduledDate != rhs.scheduledDate {
                    return lhs.scheduledDate < rhs.scheduledDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard orderedCalls.count > 1 else { return [] }

        return zip(orderedCalls, orderedCalls.dropFirst()).map { origin, destination in
            let originAddress = routeAddress(for: origin)
            let destinationAddress = routeAddress(for: destination)
            let plannedDepartureDate = origin.scheduledDate.addingTimeInterval(max(origin.duration, 0))
            let scheduledGapMinutes = Int(
                (destination.scheduledDate.timeIntervalSince(plannedDepartureDate) / 60).rounded()
            )

            return TechnicianRouteLegSnapshot(
                id: "\(origin.id.uuidString)-\(destination.id.uuidString)",
                originCallID: origin.id,
                destinationCallID: destination.id,
                originTitle: routeTitle(for: origin),
                destinationTitle: routeTitle(for: destination),
                originAddress: originAddress,
                destinationAddress: destinationAddress,
                plannedDepartureDate: plannedDepartureDate,
                scheduledGapMinutes: scheduledGapMinutes,
                readiness: readiness(
                    originAddress: originAddress,
                    destinationAddress: destinationAddress
                )
            )
        }
    }

    private static func routeAddress(for call: ServiceCall) -> String? {
        AppleMapsDirections.normalizedAddress(call.siteAddress)
            ?? AppleMapsDirections.normalizedAddress(call.customer?.address)
    }

    private static func routeTitle(for call: ServiceCall) -> String {
        let title = call.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? call.type.displayName : title
    }

    private static func readiness(
        originAddress: String?,
        destinationAddress: String?
    ) -> TechnicianRouteLegReadiness {
        switch (originAddress, destinationAddress) {
        case (nil, nil):
            return .missingBothAddresses
        case (nil, _):
            return .missingOriginAddress
        case (_, nil):
            return .missingDestinationAddress
        case let (origin?, destination?) where comparisonAddress(origin) == comparisonAddress(destination):
            return .sameAddress
        default:
            return .ready
        }
    }

    private static func comparisonAddress(_ address: String) -> String {
        address
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

struct AppleMapsTravelEstimate: Equatable, Sendable {
    let expectedTravelTime: TimeInterval
    let distanceMeters: CLLocationDistance
    let expectedDepartureDate: Date
    let expectedArrivalDate: Date
}

enum AppleMapsTravelEstimatorError: Error, Equatable {
    case invalidAddress
    case addressNotFound
    case routeUnavailable
}

/// Executes one user-requested Apple Maps estimate at a time. The object keeps
/// each MapKit request so closing the view or choosing Cancel immediately stops
/// the work. No device location is requested or retained.
@MainActor
final class AppleMapsTravelEstimator {
    private var originRequest: MKGeocodingRequest?
    private var destinationRequest: MKGeocodingRequest?
    private var directions: MKDirections?
    private var requestGeneration = UUID()

    func estimate(
        originAddress: String,
        destinationAddress: String,
        plannedDepartureDate: Date,
        completion: @escaping (Result<AppleMapsTravelEstimate, AppleMapsTravelEstimatorError>) -> Void
    ) {
        cancel()

        guard let originRequest = MKGeocodingRequest(addressString: originAddress),
              let destinationRequest = MKGeocodingRequest(addressString: destinationAddress) else {
            completion(.failure(.invalidAddress))
            return
        }

        let generation = UUID()
        requestGeneration = generation
        self.originRequest = originRequest
        self.destinationRequest = destinationRequest

        originRequest.getMapItems { [weak self] originItems, originError in
            guard let self, self.requestGeneration == generation else { return }
            guard originError == nil, let originMapItem = originItems?.first else {
                self.finish(generation: generation, result: .failure(.addressNotFound), completion: completion)
                return
            }

            destinationRequest.getMapItems { [weak self] destinationItems, destinationError in
                guard let self, self.requestGeneration == generation else { return }
                guard destinationError == nil, let destinationMapItem = destinationItems?.first else {
                    self.finish(generation: generation, result: .failure(.addressNotFound), completion: completion)
                    return
                }

                let directionsRequest = MKDirections.Request()
                directionsRequest.source = originMapItem
                directionsRequest.destination = destinationMapItem
                directionsRequest.transportType = .automobile
                directionsRequest.departureDate = max(plannedDepartureDate, Date())

                let directions = MKDirections(request: directionsRequest)
                self.directions = directions
                directions.calculateETA { [weak self] response, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestGeneration == generation else { return }
                        guard error == nil, let response else {
                            self.finish(generation: generation, result: .failure(.routeUnavailable), completion: completion)
                            return
                        }

                        self.finish(
                            generation: generation,
                            result: .success(
                                AppleMapsTravelEstimate(
                                    expectedTravelTime: response.expectedTravelTime,
                                    distanceMeters: response.distance,
                                    expectedDepartureDate: response.expectedDepartureDate,
                                    expectedArrivalDate: response.expectedArrivalDate
                                )
                            ),
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    func cancel() {
        requestGeneration = UUID()
        originRequest?.cancel()
        destinationRequest?.cancel()
        directions?.cancel()
        originRequest = nil
        destinationRequest = nil
        directions = nil
    }

    private func finish(
        generation: UUID,
        result: Result<AppleMapsTravelEstimate, AppleMapsTravelEstimatorError>,
        completion: (Result<AppleMapsTravelEstimate, AppleMapsTravelEstimatorError>) -> Void
    ) {
        guard requestGeneration == generation else { return }
        originRequest = nil
        destinationRequest = nil
        directions = nil
        completion(result)
    }
}
