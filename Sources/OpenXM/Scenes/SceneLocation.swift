import Foundation

struct SceneCoordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }

    func distance(to other: Self) -> Double {
        let rad = Double.pi / 180
        let a = latitude * rad, b = other.latitude * rad
        let dLat = (other.latitude - latitude) * rad, dLon = (other.longitude - longitude) * rad
        let value = pow(sin(dLat / 2), 2) + cos(a) * cos(b) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, value))))
    }
}

struct SceneLocationTrigger: Codable, Equatable, Sendable {
    enum Event: String, Codable, CaseIterable, Identifiable {
        case arrival, departure
        var id: String { rawValue }
        var title: String { self == .arrival ? "When I arrive" : "When I leave" }
    }
    var name = ""
    var center: SceneCoordinate?
    var radius: Double = 500
    var event: Event = .arrival
    var isValid: Bool {
        center?.isValid == true && radius.isFinite && (100...5_000).contains(radius)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100
    }
    var title: String { "\(event == .arrival ? "Arriving at" : "Leaving") \(name.isEmpty ? "a place" : name)" }
}

struct SceneLocationFix: Equatable, Sendable {
    let coordinate: SceneCoordinate
    let accuracy: Double
    let date: Date

    func isUsable(at now: Date) -> Bool {
        coordinate.isValid && accuracy.isFinite && (0...1_000).contains(accuracy)
            && (-10...120).contains(now.timeIntervalSince(date))
    }
}

/// Pure boundary tracking, separate from OS location access and all headphone writes.
/// Two distinct fixes at least 30 seconds apart must agree. The entire accuracy circle must fit inside
/// the place to arrive, or outside its radius plus hysteresis to leave. Ambiguous fixes break dwell.
struct SceneLocationTracker {
    struct Entry: Equatable { let id: UUID; let trigger: SceneLocationTrigger }
    private struct State {
        var stable: Bool?
        var proposed: Bool?
        var proposedSince: Date?
        var pending = false
    }
    private var entries: [Entry] = []
    private var states: [UUID: State] = [:]
    private var lastFix: Date?

    mutating func configure(_ entries: [Entry]) {
        let valid = entries.filter { $0.trigger.isValid }
        states = states.filter { id, _ in valid.contains { $0.id == id && self.entries.contains($0) } }
        self.entries = valid
    }

    mutating func reset() { states = [:]; lastFix = nil }

    mutating func invalidateDwell() {
        for id in states.keys { states[id]?.proposed = nil; states[id]?.proposedSince = nil }
    }

    mutating func receive(_ fix: SceneLocationFix, now: Date) {
        guard (-10...120).contains(now.timeIntervalSince(fix.date)), lastFix.map({ fix.date > $0 }) ?? true else { return }
        guard fix.isUsable(at: now) else { invalidateDwell(); return }
        // A long gap cannot count as continuous dwell, but retains a confirmed side for departure.
        if let lastFix, fix.date.timeIntervalSince(lastFix) > 120 {
            for id in states.keys { states[id]?.proposed = nil; states[id]?.proposedSince = nil; states[id]?.pending = false }
        }
        lastFix = fix.date
        for entry in entries {
            guard let center = entry.trigger.center else { continue }
            var state = states[entry.id] ?? State()
            let distance = center.distance(to: fix.coordinate)
            let radius = entry.trigger.radius
            let inside: Bool?
            if fix.accuracy > radius / 2 { inside = nil }
            else if distance + fix.accuracy <= radius { inside = true }
            else if distance - fix.accuracy >= radius + max(50, radius * 0.1) { inside = false }
            else { inside = nil }
            if let inside {
                if state.proposed != inside {
                    state.proposed = inside; state.proposedSince = fix.date
                } else if let start = state.proposedSince, fix.date.timeIntervalSince(start) >= 30, state.stable != inside {
                    let previous = state.stable
                    state.stable = inside
                    // Initial presence can apply an arrival scene. An initial outside fix is not a departure.
                    state.pending = entry.trigger.event == .arrival ? inside : (!inside && previous == true)
                }
                // Don't deliver a queued arrival after observing a clear exit, or vice versa.
                if inside != (entry.trigger.event == .arrival) { state.pending = false }
            } else {
                state.proposed = nil; state.proposedSince = nil
            }
            states[entry.id] = state
        }
    }

    func candidates(at now: Date) -> [UUID] {
        guard let lastFix, (0...120).contains(now.timeIntervalSince(lastFix)) else { return [] }
        return entries.filter { entry in
            guard let state = states[entry.id], let since = state.proposedSince else { return false }
            return state.pending && state.proposed == (entry.trigger.event == .arrival) && lastFix.timeIntervalSince(since) >= 30
        }.map(\.id)
    }

    /// All simultaneous matches are consumed together; the first scene in the user's list wins.
    mutating func consume(_ ids: [UUID]) { for id in ids { states[id]?.pending = false } }
}
