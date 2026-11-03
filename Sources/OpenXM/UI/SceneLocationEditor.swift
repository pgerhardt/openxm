import SwiftUI

struct SceneLocationEditor: View {
    @Environment(SceneStore.self) private var store
    @Environment(HeadphoneController.self) private var controller
    @Binding var place: SceneLocationTrigger
    @State private var captureTask: Task<Void, Never>?
    @State private var captureError: String?
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Place name, such as Home", text: $place.name).textFieldStyle(.roundedBorder)
            Picker("Run", selection: $place.event) {
                ForEach(SceneLocationTrigger.Event.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                if let center = place.center, center.isValid {
                    Label("Location selected", systemImage: "mappin.and.ellipse").foregroundStyle(Theme.accentSoft)
                } else {
                    Text("Choose this place’s location.").foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(store.location.capturing ? "Getting Location…" : "Use Current Location") { captureLocation() }
                    .disabled(controller.isReplay || store.location.capturing)
            }
            Stepper(value: $place.radius, in: 100...5_000, step: 100) {
                Text("Radius: \(place.radius.formatted(.number.precision(.fractionLength(0)))) m")
            }
            DisclosureGroup("Coordinates") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter decimal degrees to choose a different place. This does not request your current location.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Latitude", text: $latitude)
                        TextField("Longitude", text: $longitude)
                        Button("Set Place") { setCoordinates() }
                    }.textFieldStyle(.roundedBorder)
                }.padding(.top, 6)
            }
            Text(store.location.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.location.permission == .notDetermined && !controller.isReplay {
                Button("Allow Location for Scenes…") { store.location.requestPermission() }
            }
            if let error = captureError ?? store.location.error {
                Text(error).font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            Text("Runs while OpenXM is running and the headphones are connected, after at least 30 seconds in a reliably detected area. The first matching scene in your list wins. Place coordinates are saved locally; OpenXM keeps no location history. macOS Location Services may use network connections.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { updateCoordinateFields(); store.location.refreshPermission() }
        .onDisappear { captureTask?.cancel() }
        .onChange(of: place.center) { _, _ in updateCoordinateFields() }
    }

    private func captureLocation() {
        captureError = nil
        captureTask = Task { @MainActor in
            do {
                let fix = try await store.location.currentLocation()
                try Task.checkCancellation()
                place.center = fix.coordinate
                let previous = place.radius.isFinite && (100...5_000).contains(place.radius) ? place.radius : 500
                place.radius = max(previous, ceil(max(500, fix.accuracy * 2) / 100) * 100)
            } catch is CancellationError { }
            catch { captureError = error.localizedDescription }
            captureTask = nil
        }
    }

    private func setCoordinates() {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              SceneCoordinate(latitude: lat, longitude: lon).isValid else {
            captureError = "Enter latitude from −90 to 90 and longitude from −180 to 180, using a decimal point."
            return
        }
        place.center = .init(latitude: lat, longitude: lon); captureError = nil
    }

    private func updateCoordinateFields() {
        latitude = place.center.map { String($0.latitude) } ?? ""
        longitude = place.center.map { String($0.longitude) } ?? ""
    }
}
