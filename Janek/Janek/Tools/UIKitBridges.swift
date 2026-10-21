import MessageUI
import UIKit

enum UIPasteboardBridge {
    @MainActor static func copy(_ text: String) { UIPasteboard.general.string = text }
}

enum MessageComposerAvailability {
    @MainActor static var canSendText: Bool { MFMessageComposeViewController.canSendText() }
}
