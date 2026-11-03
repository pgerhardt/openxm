import Foundation
import Testing
@testable import OpenXM

struct SceneLocationTrackerTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let id = UUID()
    private func place(_ event: SceneLocationTrigger.Event = .arrival) -> SceneLocationTrigger {
        .init(name: "Synthetic test place", center: .init(latitude: 0, longitude: 0), radius: 500, event: event)
    }
    private func fix(_ seconds: Double, meters: Double = 0, accuracy: Double = 20) -> SceneLocationFix {
        .init(coordinate: .init(latitude: meters / 111_194.9266, longitude: 0), accuracy: accuracy, date: epoch.addingTimeInterval(seconds))
    }
    private func deliver(_ tracker: inout SceneLocationTracker, _ seconds: Double, meters: Double = 0, accuracy: Double = 20) {
        tracker.receive(fix(seconds, meters: meters, accuracy: accuracy), now: epoch.addingTimeInterval(seconds))
    }

    @Test func arrivalRequiresDistinctStableFixesAndRunsOnceUntilReentry() {
        var tracker = SceneLocationTracker(); tracker.configure([.init(id: id, trigger: place())])
        deliver(&tracker, 0)
        tracker.receive(fix(0), now: epoch.addingTimeInterval(35))
        #expect(tracker.candidates(at: epoch.addingTimeInterval(35)).isEmpty)
        deliver(&tracker, 29)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(29)).isEmpty)
        deliver(&tracker, 30)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(30)) == [id])
        tracker.consume([id]); deliver(&tracker, 60)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(60)).isEmpty)
        deliver(&tracker, 90, meters: 700); deliver(&tracker, 120, meters: 700)
        deliver(&tracker, 150); deliver(&tracker, 180)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(180)) == [id])
    }

    @Test func uncertaintyAndImprecisionCannotCompleteDwellOrDeliverAPendingEvent() {
        var tracker = SceneLocationTracker(); tracker.configure([.init(id: id, trigger: place())])
        deliver(&tracker, 0); deliver(&tracker, 20, meters: 480, accuracy: 50)
        deliver(&tracker, 30); deliver(&tracker, 50, accuracy: 300)
        deliver(&tracker, 60); deliver(&tracker, 89)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(89)).isEmpty)
        deliver(&tracker, 90)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(90)) == [id])
        deliver(&tracker, 95, meters: 500)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(95)).isEmpty)
        deliver(&tracker, 100)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(100)).isEmpty)
        deliver(&tracker, 130)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(130)) == [id])
        deliver(&tracker, 140, meters: 700)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(140)).isEmpty)
    }

    @Test func departureRequiresAnObservedInsideStateAndAnOutsideAccuracyCircle() {
        var tracker = SceneLocationTracker(); tracker.configure([.init(id: id, trigger: place(.departure))])
        deliver(&tracker, 0, meters: 700); deliver(&tracker, 30, meters: 700)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(30)).isEmpty)
        deliver(&tracker, 60); deliver(&tracker, 90)
        deliver(&tracker, 120, meters: 560, accuracy: 20); deliver(&tracker, 150, meters: 560, accuracy: 20)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(150)).isEmpty)
        deliver(&tracker, 180, meters: 600); deliver(&tracker, 210, meters: 600)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(210)) == [id])
    }

    @Test func oldInvalidFutureAndOutOfOrderFixesCannotTriggerAndGapsBreakDwell() {
        var tracker = SceneLocationTracker(); tracker.configure([.init(id: id, trigger: place())])
        tracker.receive(fix(-121), now: epoch)
        tracker.receive(fix(11), now: epoch)
        for accuracy in [-1.0, .infinity, .nan, 1_001] { tracker.receive(fix(0, accuracy: accuracy), now: epoch) }
        tracker.receive(.init(coordinate: .init(latitude: 91, longitude: 0), accuracy: 10, date: epoch), now: epoch)
        deliver(&tracker, 30)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(30)).isEmpty)
        deliver(&tracker, 160) // gap exceeds two minutes: not a second confirming fix
        #expect(tracker.candidates(at: epoch.addingTimeInterval(160)).isEmpty)
        tracker.receive(fix(60), now: epoch.addingTimeInterval(170))
        deliver(&tracker, 190)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(190)) == [id])
        #expect(tracker.candidates(at: epoch.addingTimeInterval(311)).isEmpty)
        tracker.reset(); deliver(&tracker, 320)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(320)).isEmpty)
    }

    @Test func scenePriorityChangesAndEditingOrRemovingPlacesInvalidateTheirOldState() {
        let second = UUID()
        var tracker = SceneLocationTracker()
        let a = SceneLocationTracker.Entry(id: id, trigger: place())
        let b = SceneLocationTracker.Entry(id: second, trigger: place())
        tracker.configure([a, b]); deliver(&tracker, 0); deliver(&tracker, 30)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(30)) == [id, second])
        tracker.configure([b, a])
        #expect(tracker.candidates(at: epoch.addingTimeInterval(30)) == [second, id])
        tracker.consume([second, id])
        #expect(tracker.candidates(at: epoch.addingTimeInterval(30)).isEmpty)
        var moved = place(); moved.center = .init(latitude: 1, longitude: 1)
        tracker.configure([.init(id: id, trigger: moved)])
        deliver(&tracker, 60); deliver(&tracker, 90)
        #expect(tracker.candidates(at: epoch.addingTimeInterval(90)).isEmpty)
        tracker.configure([])
        #expect(tracker.candidates(at: epoch.addingTimeInterval(90)).isEmpty)
    }

    @Test func coordinatesHandleTheDateLineAndRejectInvalidPlaces() throws {
        let a = SceneCoordinate(latitude: 0, longitude: 179.999), b = SceneCoordinate(latitude: 0, longitude: -179.999)
        #expect((220...225).contains(a.distance(to: b)))
        for coordinate in [SceneCoordinate(latitude: .nan, longitude: 0), .init(latitude: 0, longitude: 181)] { #expect(!coordinate.isValid) }
        for radius in [-1.0, 0, 99, 5_001, .infinity, .nan] {
            var invalid = place(); invalid.radius = radius; #expect(!invalid.isValid)
        }
        var noName = place(); noName.name = " \n "; #expect(!noName.isValid)
        var noCenter = place(); noCenter.center = nil; #expect(!noCenter.isValid)
        let encoded = try JSONEncoder().encode(SceneTrigger.location(place()))
        #expect(try JSONDecoder().decode(SceneTrigger.self, from: encoded) == .location(place()))
        #expect(try JSONDecoder().decode(SceneTrigger.self, from: Data("{\"onConnect\":{}}".utf8)) == .onConnect)
    }
}

@MainActor private final class TestLocationProvider: SceneLocationProvider {
    var permission: SceneLocationPermission = .notDetermined
    var onPermission: (() -> Void)?
    var onFix: ((SceneLocationFix) -> Void)?
    var onError: ((String) -> Void)?
    var permissionRequests = 0, fixRequests = 0, cancellations = 0
    func requestPermission() { permissionRequests += 1 }
    func requestFix() { fixRequests += 1 }
    func cancelRequest() { cancellations += 1 }
    func changePermission(_ value: SceneLocationPermission) { permission = value; onPermission?() }
    func fix(date: Date = Date(), accuracy: Double = 20) {
        onFix?(.init(coordinate: .init(latitude: 0, longitude: 0), accuracy: accuracy, date: date))
    }
}

@MainActor struct SceneLocationServiceTests {
    @Test func automatedMonitoringNeverRequestsPermissionAndRevocationStopsRequests() {
        let provider = TestLocationProvider()
        var creations = 0, unavailable = 0, received = 0
        let service = SceneLocationService(makeProvider: { creations += 1; return provider })
        service.onUnavailable = { unavailable += 1 }; service.onFix = { _ in received += 1 }
        service.setMonitoring(false)
        #expect(creations == 0)
        service.setMonitoring(true)
        #expect(creations == 1 && !service.monitoring && provider.permissionRequests == 0 && provider.fixRequests == 0)
        service.requestPermission()
        #expect(provider.permissionRequests == 1)
        provider.changePermission(.authorized)
        #expect(service.monitoring && provider.fixRequests == 1)
        provider.fix(); #expect(received == 1)
        service.setMonitoring(true); service.refreshPermission()
        #expect(provider.fixRequests == 1) // UI/connection observations must not turn polling into a tight loop.
        provider.changePermission(.denied)
        #expect(!service.monitoring && unavailable == 1)
        provider.fix(); #expect(received == 1)
        service.setMonitoring(true)
        #expect(provider.permissionRequests == 1 && provider.fixRequests == 1)
        service.setMonitoring(false)
    }

    @Test func oneTimeCaptureRequestsPermissionOnlyAfterExplicitActionAndStopsAfterAFix() async throws {
        let provider = TestLocationProvider()
        let service = SceneLocationService(makeProvider: { provider })
        let task = Task { try await service.currentLocation() }
        for _ in 0..<10 where !service.capturing { await Task.yield() }
        try #require(service.capturing)
        #expect(provider.permissionRequests == 1 && provider.fixRequests == 0)
        provider.changePermission(.authorized)
        #expect(provider.fixRequests == 1)
        provider.fix()
        let fix = try await task.value
        #expect(fix.coordinate == .init(latitude: 0, longitude: 0))
        #expect(!service.capturing && !service.monitoring && provider.cancellations == 1)
    }

    @Test func cancellationAndPermissionDenialFinishPendingCaptureWithoutALocation() async throws {
        let provider = TestLocationProvider(); provider.permission = .authorized
        let service = SceneLocationService(makeProvider: { provider })
        let task = Task { try await service.currentLocation() }
        for _ in 0..<10 where !service.capturing { await Task.yield() }
        try #require(service.capturing)
        provider.fix(date: Date().addingTimeInterval(-500))
        #expect(service.capturing)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled capture returned coordinates") }
        catch { #expect(error is CancellationError) }
        #expect(!service.capturing)
        let denied = Task { try await service.currentLocation() }
        for _ in 0..<10 where !service.capturing { await Task.yield() }
        try #require(service.capturing)
        provider.changePermission(.denied)
        do { _ = try await denied.value; Issue.record("Denied capture returned coordinates") } catch { }
        #expect(!service.capturing && !service.monitoring)
    }

    @Test func replayAndDisabledServicesCannotStartLocationRequests() async {
        var creations = 0
        let replay = SceneLocationService(allowsLocation: { false }, makeProvider: { creations += 1; return TestLocationProvider() })
        replay.setMonitoring(true); replay.requestPermission(); replay.refreshPermission()
        do { _ = try await replay.currentLocation(); Issue.record("Replay obtained a location") } catch { }
        #expect(creations == 0 && !replay.monitoring)
        let provider = TestLocationProvider(); provider.permission = .servicesDisabled
        let disabled = SceneLocationService(makeProvider: { provider })
        disabled.setMonitoring(true); disabled.requestPermission()
        do { _ = try await disabled.currentLocation(); Issue.record("Disabled location services succeeded") } catch { }
        #expect(provider.permissionRequests == 0 && provider.fixRequests == 0)
    }

    @Test func savedPlaceRoundTripsWithoutSamplesAndInvalidPlacesCannotBeSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scenes.json")
        let controller = HeadphoneController(); controller.startDemo()
        let store = SceneStore(controller: controller, fileURL: file)
        var scene = SoundScene(name: "Synthetic location scene", symbol: "house", tint: .sage, upscaling: true)
        scene.trigger = .location(.init())
        store.upsert(scene)
        #expect(store.scenes.isEmpty && store.saveError != nil && !FileManager.default.fileExists(atPath: file.path))
        scene.trigger = .location(.init(name: "Test origin", center: .init(latitude: 0, longitude: 0), radius: 500))
        store.upsert(scene)
        let data = try Data(contentsOf: file)
        #expect(try JSONDecoder().decode([SoundScene].self, from: data) == [scene])
        #expect(!store.location.monitoring)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("accuracy") && !text.contains("lastFix") && !text.contains("history"))
    }
}
