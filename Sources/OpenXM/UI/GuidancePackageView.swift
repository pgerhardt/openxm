import SwiftUI

struct GuidancePackageView: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        @Bindable var workflow = controller.guidancePackages
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Voice Language Packages").font(.title2.bold())
                Spacer()
                Button("Done") { workflow.isPresented = false }.disabled(workflow.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Download and preserve a voice package offered for your international WH-1000XM3. Installation is experimental and has not yet been verified on hardware.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let requested = workflow.requestedBackupLanguage {
                        Text("Your settings backup requests \(requested.title). Connect the international WH-1000XM3 and choose Check Sony to read its language service and find an eligible package. Opening this review does not download or install anything.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Open Saved Package…") { workflow.openPackageBackup() }.disabled(!workflow.canOpenPackageBackup)
                        Button("Export Package…") { workflow.exportPackageBackup() }.disabled(!workflow.canExportPackageBackup)
                    }
                    if let saved = workflow.packageBackup {
                        GuidancePackageBackupSummary(saved: saved, name: workflow.packageBackupName ?? "Saved package", checked: workflow.archive != nil)
                        HStack {
                            Button("Check Saved Package") { workflow.checkSavedPackage() }.disabled(!workflow.canCheckSavedPackage)
                            Button("Close Saved Package") { workflow.closePackageBackup() }.disabled(workflow.busy || workflow.hasSession)
                        }
                    }
                    if let error = workflow.sessionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let session = workflow.journal {
                        GuidanceSessionView(session: session, canCheck: workflow.canCheckPreparation,
                            canCancelPreparation: workflow.canCancelPreparation,
                            check: { workflow.checkPreparation() }, cancelPreparation: { workflow.cancelPreparation() })
                    }
                    Picker("Language", selection: $workflow.language) {
                        Text("Choose a language").tag(Optional<GuidanceLanguage>.none)
                        ForEach(workflow.languages) { language in
                            Text(language.title).tag(Optional(language))
                        }
                    }.disabled(workflow.busy || workflow.hasSession || workflow.packageBackup != nil)
                    if let source = workflow.source, let offer = source.metadata.offer {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            GridRow { Text("Checked for").foregroundStyle(.secondary); Text("\(source.request.model) · firmware \(source.request.firmware)") }
                            GridRow { Text("Package").foregroundStyle(.secondary); Text("\(source.request.language.title) · version \(offer.version)") }
                            GridRow { Text("Download size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: Int64(offer.size), countStyle: .file)) }
                        }
                        GuidancePackageNoticeView(offer: offer, notice: workflow.notice)
                        if workflow.archive != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Preparation check").font(.headline)
                                    Spacer()
                                    Button("Check Headphones") { workflow.checkPreparation() }.disabled(!workflow.canCheckPreparation)
                                }
                                Text("Reads the current language, update method and battery, and checks the saved package and notice again. This does not start installation.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if let result = workflow.preflight { GuidancePreflightView(result: result) }
                                Button(workflow.installTitle) { workflow.install() }
                                    .buttonStyle(.borderedProminent).disabled(!workflow.canInstall)
                            }
                        }
                        DisclosureGroup("Source and integrity") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Service: \(source.request.category) / \(source.request.service)")
                                Text(offer.url.absoluteString)
                                Text("SHA-1: \(offer.sha1)")
                                if let archive = workflow.archive { Text("SHA-256: \(archive.sha256)") }
                                Text("The saved folder includes the original metadata and a provenance record. Integrity checks do not verify installation compatibility.").foregroundStyle(.secondary)
                            }.font(.caption).textSelection(.enabled).padding(.top, 6)
                        }
                    }
                    if let fraction = workflow.fraction { ProgressView(value: fraction) }
                    else if workflow.busy { ProgressView().controlSize(.small) }
                    if workflow.isInstalling, let phase = workflow.transferPhase {
                        Text(phase == .complete ? "Package committed; checking language and update mode…" : "Language installation: \(phase.rawValue)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let message = workflow.message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let error = workflow.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if !controller.isConnected && !workflow.busy && !workflow.hasSession { Text("Connect the headphones to check for a package.").font(.callout).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if workflow.busy && !workflow.isInstalling { Button("Stop") { workflow.stop() } }
                if workflow.archive != nil { Button("Show in Finder") { workflow.revealArchive() } }
                if workflow.notice != nil { Button("Show Notice") { workflow.revealNotice() } }
                Spacer()
                Button("Check Sony") { workflow.check() }.disabled(!workflow.canCheck)
                Button("Download Package") { workflow.download() }.buttonStyle(.borderedProminent).disabled(!workflow.canDownload)
            }
        }
        .padding(24).frame(width: 660, height: workflow.source?.metadata.offer == nil && !workflow.hasSession && workflow.packageBackup == nil ? (workflow.requestedBackupLanguage == nil ? 380 : 470) : 640)
        .interactiveDismissDisabled(workflow.busy)
    }
}

struct GuidancePackageBackupSummary: View {
    let saved: GuidancePackageBackup
    let name: String
    let checked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.headline)
            Text("Saved for \(saved.context.model) · firmware \(saved.context.firmwareAtDiscovery)")
            Text("\(saved.context.language.title) · package \(saved.context.packageVersion) · \(ByteCountFormatter.string(fromByteCount: Int64(saved.package.data.count), countStyle: .file))")
            Text(checked ? "Checked against the connected headphones' language service and original metadata rules. Installation preparation is still required."
                 : "File hashes and metadata envelope checked. Headphone eligibility has not been checked. These checks do not verify a publisher signature.")
                .foregroundStyle(.secondary)
            DisclosureGroup("Saved file details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Service: \(saved.context.category) / \(saved.context.service)")
                    Text("Package SHA-256: \(saved.package.sha256)")
                    Text("Metadata SHA-256: \(saved.metadata.sha256)")
                    Text(saved.notice == nil ? "No notice file saved." : "Saved notice and provenance are included.")
                }.font(.caption).textSelection(.enabled)
            }
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

struct GuidancePreflightView: View {
    let result: GuidancePreflight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(result.currentLanguage.title) → \(result.targetLanguage.title)")
            Text("Battery \(result.battery)% · Minimum for preparation \(result.minimumBattery)%")
            Text(result.supportsResume ? "The headphones advertise a resumable CSR update method."
                 : "The headphones advertise a CSR update method without resume support.")
            Text("Checked \(result.checkedAt.formatted()). Installation checks these readings again after your confirmation.")
                .foregroundStyle(.secondary)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

/// Plain-text notice display is shared with UI previews; no agreement or installation is performed here.
struct GuidancePackageNoticeView: View {
    let offer: GuidancePackageOffer
    let notice: GuidanceNoticeArchive?
    @State private var instructionLanguage: String?
    @State private var noticeLocale: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let instructions = offer.instructions,
               let entry = instructions.entries.first(where: { $0.language == instructionLanguage }) ?? instructions.preferred {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sony preparation instructions").font(.headline)
                    Picker("Instruction language", selection: Binding(get: { entry.language }, set: { instructionLanguage = $0 })) {
                        ForEach(instructions.entries) { Text($0.language).tag($0.language) }
                    }
                    Text(verbatim: entry.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notice,
               let entry = notice.document.entries.first(where: { $0.locale == noticeLocale }) ?? notice.document.preferred {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sony package notice").font(.headline)
                    Picker("Notice locale", selection: Binding(get: { entry.locale }, set: { noticeLocale = $0 })) {
                        ForEach(notice.document.entries) { Text($0.locale).tag($0.locale) }
                    }
                    Text(verbatim: entry.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Original notice saved and checked against Sony's metadata.").font(.caption).foregroundStyle(.secondary)
                }
            } else if offer.notice != nil {
                Text("Sony references a package notice that has not been read. Check Sony again to retry.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GuidanceSessionView: View {
    let session: GuidanceJournal
    let canCheck: Bool
    var canCancelPreparation = false
    let check: () -> Void
    var cancelPreparation: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.canCancelPreparation ? "Unfinished language preparation"
                 : session.phase == .complete ? "Language installation awaiting verification" : "Unfinished language installation").font(.headline)
            Text("\(session.sourceLanguage.title) → \(session.targetLanguage.title) · \(session.started.formatted())")
            Text("Connect the original headphones to this Mac, then check the saved session. Its original package and notice will be read again.")
                .font(.callout).foregroundStyle(.secondary)
            if session.transferStarted && session.method.code == 0x10 && session.phase != .complete {
                Text("This headset did not advertise transfer resume. The session is preserved, but OpenXM cannot safely restart it.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if session.canCancelPreparation {
                Text("No transfer started. You can also cancel this preparation after the original language and normal update mode are verified. Downloaded files stay saved.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check Saved Session", action: check).disabled(!canCheck)
                if session.canCancelPreparation {
                    Button("Cancel Preparation…", action: cancelPreparation).disabled(!canCancelPreparation)
                }
            }
        }
    }
}
