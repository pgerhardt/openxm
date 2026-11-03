import AppKit

/// A concrete, cancel-first review of the already validated installation.
@MainActor enum GuidanceInstallConfirmation {
    static func cancellationAlert(for review: GuidancePreparationReview) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Cancel language-update preparation?"
        alert.informativeText = "The saved session records that no language transfer started. OpenXM will restore normal update mode and verify that these headphones still report \(review.journal.sourceLanguage.title) before clearing the preparation. Downloaded packages and notices stay saved. No package will be uploaded. This recovery path has not yet been verified on hardware."
        alert.addButton(withTitle: "Keep Preparation")
        alert.addButton(withTitle: "Cancel Preparation")
        return alert
    }

    static func alert(for review: GuidanceInstallReview) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = review.plan == .verifyCompleted ? "Finish verifying \(review.snapshot.request.language.title)?"
            : "\(review.journal == nil ? "Install" : "Resume") \(review.snapshot.request.language.title) voice guidance?"
        let recovery = review.snapshot.method.code == 0x10 ? "This headset does not advertise transfer resume; OpenXM cannot restart an interrupted transfer. " : "Interrupted-transfer recovery has not been verified on hardware. "
        alert.informativeText = review.plan == .verifyCompleted
            ? "The package was already committed. OpenXM will confirm normal language mode and independently read the installed language. It will not upload the package again."
            : "Experimental international WH-1000XM3 language installer, not yet verified on hardware. A failure could leave the headphones unusable. \(recovery)Review Sony's preparation instructions and package notice in the sheet before continuing. Fully charge the headphones and Mac, unplug USB and audio cables, stop playback, and keep the Mac awake and nearby until verification finishes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: review.plan == .verifyCompleted ? "Finish Verification" : "Continue Installation")
        return alert
    }
}
