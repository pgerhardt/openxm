import SwiftUI

/// Model-specific phone setup, keyed by Sony's advertised semantic names rather than list positions.
/// Selection is not evidence that a phone has authenticated or activated the assistant.
enum XM3AssistantGuide: String, Identifiable, CaseIterable {
    case google, alexa, xiaowei

    var id: String { rawValue }

    static func selected(setting: GeneralSetting, model: String?) -> Self? {
        guard model == "WH-1000XM3", setting.isButtonAssignment, setting.isList else { return nil }
        switch setting.selectedOption?.key {
        case "ASSIGNABLE_KEY_ELEM_GOOGLE_ASSISTANT": return .google
        case "ASSIGNABLE_KEY_ELEM_AMAZON_ALEXA": return .alexa
        case "ASSIGNABLE_KEY_ELEM_TENCENT_XIAOWEI": return .xiaowei
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .google: "Google Assistant"
        case .alexa: "Amazon Alexa"
        case .xiaowei: "Tencent Xiaowei"
        }
    }

    var requirements: String {
        switch self {
        case .google: "Requires a compatible Android phone with Google's apps and an internet connection. Google Assistant headphone integration is not available on iOS."
        case .alexa: "Requires the Alexa app on a compatible Android phone or iPhone. Sony lists WH-1000XM3 firmware 4.1.1 or later for Alexa support."
        case .xiaowei: "Sony documents Xiaowei for customers in mainland China, with Chinese-language service and a compatible Tencent Xiaowei app on Android or iPhone. Current service availability depends on Tencent."
        }
    }

    var steps: [String] {
        switch self {
        case .google: [
            "Pair and connect the headphones to your Android phone using Bluetooth.",
            "Open the phone's headphone setup notification, or open Google Assistant and choose Finish headphones setup when offered. Follow the phone's setup instructions.",
            "With Google Assistant selected for NC/AMBIENT, hold the button to speak. Available responses depend on the phone's current Assistant features."
        ]
        case .alexa: [
            "Pair and connect the headphones to your phone using Bluetooth, then open the Alexa app.",
            "In Alexa, choose Add Device, then Headphones and WH-1000XM3. Follow the pairing and assistant setup prompts. On iPhone, the device may appear with an LE_ prefix.",
            "With Amazon Alexa selected for NC/AMBIENT, press the button to speak. Press again to cancel."
        ]
        case .xiaowei: [
            "Pair and connect the headphones to your phone using Bluetooth.",
            "Open the Tencent Xiaowei app and complete its setup. Use Sony's linked instructions for supported app requirements.",
            "With Tencent Xiaowei selected for NC/AMBIENT, hold the button to speak."
        ]
        }
    }

    var sonyURL: URL {
        switch self {
        case .google: URL(string: "https://helpguide.sony.net/mdr/wh1000xm3/v1/en/contents/TP0001867145.html")!
        case .alexa: URL(string: "https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wh-1000xm3/articles/00225624")!
        case .xiaowei: URL(string: "https://helpguide.sony.net/mdr/wh1000xm3/v1/zh-cn/contents/TP0002089602.html")!
        }
    }
}

struct AssistantSetupView: View {
    let guide: XM3AssistantGuide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set Up \(guide.title)").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("OpenXM changes the headphone button assignment. Complete assistant activation on your phone.")
                .font(.callout).foregroundStyle(.secondary)
            Text(guide.requirements).font(.callout)
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("While assigned to an assistant, NC/AMBIENT no longer switches noise control or starts the NC Optimizer. Those controls remain available in OpenXM.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Link("Sony's Setup Guide", destination: guide.sonyURL)
                ShareLink(item: guide.sonyURL) { Label("Share Guide…", systemImage: "square.and.arrow.up") }
                if guide == .google {
                    Link("Current Google Requirements", destination: URL(string: "https://support.google.com/assistant/answer/9027902?hl=en")!)
                }
            }
            Text("Phone activation status is not reported to OpenXM.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 570)
    }
}
