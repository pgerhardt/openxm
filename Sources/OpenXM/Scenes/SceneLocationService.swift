import Foundation
import CoreLocation
import Observation

enum SceneLocationPermission: Equatable {
    case notDetermined, authorized, denied, restricted, servicesDisabled
}

@MainActor
protocol SceneLocationProvider: AnyObject {
    var permission: SceneLocationPermission { get }
    var onPermission: (() -> Void)? { get set }
    var onFix: ((SceneLocationFix) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func requestPermission()
    func requestFix()
    func cancelRequest()
}

@MainActor
final class CoreLocationSceneProvider: NSObject, SceneLocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onPermission: (() -> Void)?
    var onFix: ((SceneLocationFix) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    var permission: SceneLocationPermission {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesDisabled }
        switch manager.authorizationStatus {
        case .authorizedAlways: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }
    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func requestFix() { manager.requestLocation() }
    func cancelRequest() { manager.stopUpdatingLocation() }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onPermission?() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        let fix = SceneLocationFix(coordinate: .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                                   accuracy: location.horizontalAccuracy, date: location.timestamp)
        Task { @MainActor [weak self] in self?.onFix?(fix) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.onError?(message) }
    }
}

/// Creates no location manager until the feature is used. Only explicit UI actions request permission.
/// Monitoring uses one-shot fixes every 30 seconds while enabled scenes and connected headphones need it.
@MainActor @Observable
final class SceneLocationService {
    private(set) var permission: SceneLocationPermission = .notDetermined
    private(set) var monitoring = false
    private(set) var capturing = false
    private(set) var error: String?
    var onFix: ((SceneLocationFix) -> Void)?
    var onUnavailable: (() -> Void)?
    var onUncertain: (() -> Void)?
    private let allowsLocation: () -> Bool
    private let makeProvider: @MainActor () -> SceneLocationProvider
    private var provider: SceneLocationProvider?
    private var wanted = false
    private var requestInFlight = false
    private var pollTimer: Timer?
    private var requestTimeout: Task<Void, Never>?
    private var captureTimeout: Task<Void, Never>?
    private var captureRetry: Task<Void, Never>?
    private var capture: CheckedContinuation<SceneLocationFix, Error>?

    init(allowsLocation: @escaping () -> Bool = { true },
         makeProvider: @escaping @MainActor () -> SceneLocationProvider = { CoreLocationSceneProvider() }) {
        self.allowsLocation = allowsLocation; self.makeProvider = makeProvider
    }

    var status: String {
        if !allowsLocation() { return "Location access is disabled in replay and demo mode." }
        switch permission {
        case .notDetermined: return "Location permission has not been requested."
        case .denied: return "Location access is denied. You can change it in System Settings → Privacy & Security → Location Services."
        case .restricted: return "Location access is restricted on this Mac."
        case .servicesDisabled: return "Location Services are turned off in System Settings."
        case .authorized: return monitoring ? "Checking location while your headphones are connected." : "Location access is allowed. Checks start with an enabled place scene and connected headphones."
        }
    }

    func refreshPermission() {
        guard allowsLocation() else { return }
        ensureProvider()
        permissionChanged()
    }

    func requestPermission() {
        guard allowsLocation() else { return }
        refreshPermission()
        if permission == .notDetermined { provider?.requestPermission() }
    }

    func setMonitoring(_ enabled: Bool) {
        wanted = enabled && allowsLocation()
        if wanted { refreshPermission() } else { reconcile() }
    }

    func cancelCapture() { finishCapture(.failure(CancellationError())) }

    func currentLocation() async throws -> SceneLocationFix {
        guard allowsLocation(), !capturing else { throw LocationError.message("Location capture is unavailable.") }
        try Task.checkCancellation()
        refreshPermission()
        guard permission == .authorized || permission == .notDetermined else { throw LocationError.message(status) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                capture = continuation; capturing = true; error = nil
                captureTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)); self?.finishCapture(.failure(LocationError.message("A recent location could not be obtained. Try again."))) }
                    catch { }
                }
                if permission == .notDetermined { provider?.requestPermission() }
                else { requestFix() }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishCapture(.failure(CancellationError())) } }
    }

    private func ensureProvider() {
        guard provider == nil else { return }
        let created = makeProvider()
        created.onPermission = { [weak self] in self?.permissionChanged() }
        created.onFix = { [weak self] in self?.received($0) }
        created.onError = { [weak self] in self?.failed($0) }
        provider = created
    }

    private func permissionChanged() {
        permission = provider?.permission ?? .notDetermined
        if permission != .authorized && permission != .notDetermined {
            finishCapture(.failure(LocationError.message(status)))
        }
        reconcile()
    }

    private func reconcile() {
        let active = wanted && allowsLocation() && permission == .authorized
        let needsInitialRequest = active && !monitoring
        if active != monitoring {
            monitoring = active
            pollTimer?.invalidate(); pollTimer = nil
            if active {
                pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.requestFix() }
                }
            } else { onUnavailable?() }
        }
        if permission == .authorized && (needsInitialRequest || capturing) { requestFix() }
        else if monitoring { return }
        else if !capturing || permission != .notDetermined { cancelRequest() }
    }

    private func requestFix() {
        guard allowsLocation(), permission == .authorized, (monitoring || capturing), !requestInFlight else { return }
        requestInFlight = true
        requestTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(55)); self?.failed("Location request timed out.") }
            catch { }
        }
        provider?.requestFix()
    }

    private func received(_ fix: SceneLocationFix) {
        guard requestInFlight else { return }
        cancelRequest()
        guard allowsLocation(), permission == .authorized else { return }
        guard fix.isUsable(at: Date()) else {
            onUncertain?()
            error = "Waiting for a recent, more precise location."
            if capturing {
                captureRetry?.cancel()
                captureRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)); self?.requestFix() } catch { }
                }
            }
            return
        }
        error = nil
        if monitoring { onFix?(fix) }
        if capturing { finishCapture(.success(fix)) }
    }

    private func failed(_ message: String) {
        guard requestInFlight else { return }
        cancelRequest(); error = message; onUncertain?()
        if capturing { finishCapture(.failure(LocationError.message(message))) }
    }

    private func finishCapture(_ result: Result<SceneLocationFix, Error>) {
        guard let continuation = capture else { return }
        capture = nil; capturing = false
        captureTimeout?.cancel(); captureTimeout = nil
        captureRetry?.cancel(); captureRetry = nil
        if !monitoring { cancelRequest() }
        continuation.resume(with: result)
    }

    private func cancelRequest() {
        requestTimeout?.cancel(); requestTimeout = nil
        if requestInFlight { provider?.cancelRequest() }
        requestInFlight = false
    }
    private enum LocationError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}
