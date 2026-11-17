import UIKit
import UniformTypeIdentifiers

/// The iOS file picker, presented by UIKit itself and asking for copies: the files it hands back are already inside
/// the app, so nothing depends on permission to read someone else's folder, and no SwiftUI sheet can take the picker's
/// delegate away while it is still reporting. (SwiftUI's `.fileImporter` was used first and, on the iPhone, never
/// reported what was picked.)
@MainActor
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePicker()

    private var onFiles: (([URL]) -> Void)?

    /// Show the picker over whatever is on screen. `onFiles` is called with what was picked, possibly more than once.
    func present(onFiles: @escaping ([URL]) -> Void) {
        guard let top = FilePicker.topController() else { Log.shared.add("error", "picker: nothing to present from"); return }
        // .data lets any file be chosen: a script without an extension, or one iOS files under an odd type, is not greyed out
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .text, .json, .zip, .data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        if let dir = Demo.pickerDirectory { picker.directoryURL = dir }
        self.onFiles = onFiles
        Log.shared.add("picker", "opened")
        top.present(picker, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.flatMap { $0.windows }.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Log.shared.add("picker", "picked \(urls.count): " + urls.map { $0.lastPathComponent }.joined(separator: ", "))
        Task { @MainActor in self.onFiles?(urls) }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Log.shared.add("picker", "cancelled")
    }
}
