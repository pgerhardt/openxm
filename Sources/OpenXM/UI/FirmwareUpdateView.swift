import SwiftUI

struct FirmwareUpdateCard: View {
    @Environment(HeadphoneController.self) private var controller
    var body: some View {
        Card("Headphone Firmware", symbol: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 14) {
                Text(controller.firmwareControlsReserved
                     ? "An update has reserved the headphone connection. Open its status to check or resume the saved installation."
                     : "Check Sony's update information, verify a package and install original international, Japanese or Chinese XM3 firmware.")
                    .font(.body15).foregroundStyle(Theme.secondary)
                Button(controller.guidancePackages.hasSession ? "Language Update Status…" : controller.firmwareControlsReserved ? "Firmware Status…" : "Headphone Firmware…") {
                    if controller.guidancePackages.hasSession { controller.guidancePackages.open() }
                    else { controller.firmwareUpdate.present() }
                }
            }
        }
    }
}

struct FirmwareUpdateView: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let update = controller.firmwareUpdate
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Headphone Firmware").font(.title2.bold())
                Spacer()
                Button("Done") { update.isPresented = false }.disabled(update.busy)
            }
            Text("Experimental WH-1000XM3 updater. 10 original packages across International, Japan and China regions.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = update.sessionError { Text(error).foregroundStyle(.red) }
                    if let journal = update.journal {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(journal.phase == .complete ? "Installation awaiting version verification" : "Unfinished firmware installation").fontWeight(.semibold)
                            Text("\(update.selectedTransition?.source.label ?? journal.sourceVersion) → \(journal.targetRelease?.label ?? journal.targetVersion) · \(journal.started.formatted())")
                            Text("Reconnect the original headphones and select the same package. The device determines where to resume.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Sony update information").font(.headline)
                            Spacer()
                            Button("Check Server") { update.checkServer() }.disabled(update.busy)
                        }
                        if let metadata = update.metadata {
                            Text("\(metadata.region.title) · Listed firmware: \(Set(metadata.offers.map(\.targetVersion)).sorted().joined(separator: ", "))")
                            if let identity = update.identity, identity.region == metadata.region {
                                let version = identity.version
                                let offers = metadata.offers.filter { $0.sourceVersion == version }
                                Text(offers.isEmpty ? "This response has no update rule for firmware \(version)."
                                     : "From \(version): \(Set(offers.map(\.targetVersion)).sorted().joined(separator: ", "))")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let date = update.checkedAt { Text("Checked \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Text("Checks the selected package region's public update metadata. No package is downloaded automatically.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Package").font(.headline)
                            Spacer()
                            Picker("Region", selection: Binding(get: { update.selectedRelease.region }, set: update.selectRegion)) {
                                ForEach(FirmwareRegion.allCases) { Text($0.title).tag($0) }
                            }.fixedSize().disabled(update.busy || update.journal != nil)
                            Picker("Firmware version", selection: Binding(get: { update.selectedRelease }, set: update.selectRelease)) {
                                ForEach(update.regionReleases) { Text($0.version).tag($0) }
                            }.fixedSize().disabled(update.busy || update.journal != nil)
                        }
                        Text("\(update.selectedRelease.region.title) package · \(update.selectedRelease.provenance) · \(ByteCountFormatter.string(fromByteCount: Int64(update.selectedRelease.size), countStyle: .file))")
                            .font(.callout).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Your headphones").font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Refresh") { update.checkHeadphones() }.disabled(!update.canReadDevice)
                            }
                            HStack(alignment: .top, spacing: 16) {
                                deviceDetail("Model", value: update.identity?.model)
                                deviceDetail("Region", value: update.identity?.regionName)
                                    .help(update.identity.map { "Firmware service: \($0.category)/\($0.service)" } ?? "Read from the headphones' firmware service")
                                deviceDetail("Firmware", value: update.identity?.version)
                                deviceDetail("Battery", value: update.identity.map { "\($0.battery)%\($0.charging ? " · USB connected" : "")" })
                            }
                            if let date = update.identityDate {
                                Text("Read \(date.formatted(date: .omitted, time: .standard)). Checked again before installation.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if !update.busy {
                                Text(update.error == nil ? "Connect your headphones. Their details will appear automatically."
                                     : "Headphone details could not be read. Reconnect or choose Refresh to retry.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        if let warning = update.regionWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(FirmwareTransition.durationGuidance)
                            Text(FirmwareIdentity.powerGuidance)
                                .foregroundStyle(update.identity.map { $0.battery < FirmwareIdentity.minimumBattery || $0.charging } == true ? Color.red : Color.secondary)
                        }.font(.callout)
                        HStack {
                            Button("Download Package") { update.download() }.disabled(update.busy)
                            Button("Choose File…") { update.chooseFile() }.disabled(update.busy)
                            if update.verifiedURL != nil { Button("Show File") { update.showPackage() } }
                        }
                        if let file = update.verifiedURL, let release = update.verifiedRelease {
                            Label("Verified pinned \(release.label) package", systemImage: "checkmark.seal")
                                .foregroundStyle(.green)
                            Text(file.lastPathComponent).font(.caption).textSelection(.enabled)
                            DisclosureGroup("Package details") {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(update.packageSource ?? "").font(.caption)
                                    Text("\(release.size) bytes · HP001/\(release.region.serviceID)").font(.caption)
                                    Text("SHA-256: \(release.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Text("The hash identifies the preserved package bytes; this app does not verify Sony's signing key.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if let plan = update.installPlan {
                        Text(plan.transition.hardwareEvidence).font(.callout).foregroundStyle(.secondary)
                    } else if update.identity != nil, let reason = update.eligibilityMessage {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                    if update.isInstalling {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stageTitle(update.transferPhase)).fontWeight(.semibold)
                            if update.transferPhase == .transferring, update.transferTotal > 0 {
                                ProgressView(value: Double(update.transferred), total: Double(update.transferTotal))
                                Text("\(update.transferred * 100 / update.transferTotal)% of package bytes transferred. Validation, installation and version verification follow.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { ProgressView().controlSize(.small) }
                            Text("Keep the Mac awake and headphones nearby. Leave USB and audio cables disconnected.")
                                .font(.callout)
                        }
                    } else if update.busy {
                        if let total = update.downloadTotal {
                            ProgressView(value: Double(update.downloaded), total: Double(total))
                        } else { ProgressView().controlSize(.small) }
                    }
                    if let message = update.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let error = update.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(.trailing, 8)
            }.frame(minHeight: 360, maxHeight: 550)
            HStack {
                if update.busy && !update.isInstalling { Button("Cancel") { update.cancelPreparation() } }
                if update.reportURL != nil { Button("Show Log") { update.showReport() } }
                Spacer()
                Button(update.installPlan?.buttonTitle ?? "Install…") { update.install() }
                    .buttonStyle(.borderedProminent).disabled(update.busy || update.installPlan == nil)
            }
        }
        .padding(24).frame(width: 710)
        .interactiveDismissDisabled(update.busy)
        .onChange(of: update.identityReadContext, initial: true) { _, _ in update.refreshIdentityIfNeeded() }
    }

    private func deviceDetail(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout.weight(.medium)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stageTitle(_ phase: VMUTransfer.Phase?) -> String {
        switch phase {
        case nil: "Checking installation request"
        case .preparing: "Preparing firmware transfer"
        case .transferring: "Transferring firmware"
        case .validating: "Headphones are validating the package"
        case .rebooting: "Waiting for headphones to restart"
        case .committing: "Finishing installation"
        case .complete: "Verifying installed firmware version"
        }
    }
}
