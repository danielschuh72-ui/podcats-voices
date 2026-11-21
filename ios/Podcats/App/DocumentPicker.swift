import UIKit
import UniformTypeIdentifiers

/// The iOS file picker, presented by UIKit itself, so no SwiftUI sheet can take the picker's delegate away while it is
/// still reporting. (SwiftUI's `.fileImporter` was used first and, on the iPhone, never reported what was picked.)
///
/// The files are opened where they are and copied into the app here, one by one, each with its own entry in the log.
/// Asking the picker for copies (`asCopy: true`) was tried: with two files selected it sometimes handed back only one.
@MainActor
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePicker()

    private var onFiles: (([URL]) -> Void)?

    /// Show the picker over whatever is on screen. `onFiles` is called with what was picked, possibly more than once.
    func present(onFiles: @escaping ([URL]) -> Void) {
        guard let top = FilePicker.topController() else { Log.shared.add("error", "picker: nothing to present from"); return }
        // .data lets any file be chosen: a script without an extension, or one iOS files under an odd type, is not greyed out
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .text, .json, .zip, .data], asCopy: Updates.shared.pickerCopies)
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
        let local = FilePicker.copyIn(urls)
        Task { @MainActor in self.onFiles?(local) }
    }

    /// Copies of the picked files inside the app. A file that cannot be copied is passed on as it is, so that the
    /// import says so by name instead of leaving it out silently.
    nonisolated static func copyIn(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("picked-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for (i, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var data: Data?
            var readError: Error?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
                do { data = try Data(contentsOf: u) } catch { readError = error }
            }
            if data == nil, coordError == nil, readError == nil { do { data = try Data(contentsOf: url) } catch { readError = error } }
            guard let d = data else {
                let why = (coordError as Error?) ?? readError
                Log.shared.add("error", "picker: \(url.lastPathComponent) not readable (scoped \(scoped)): " + (why.map { Log.text($0) } ?? "no data"))
                out.append(url)
                continue
            }
            // a folder each, so two files with the same name from different places both keep their name
            let sub = dir.appendingPathComponent(String(i), isDirectory: true)
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            let copy = sub.appendingPathComponent(url.lastPathComponent)
            do { try d.write(to: copy); out.append(copy) } catch {
                Log.shared.error("picker: copy \(url.lastPathComponent)", error)
                out.append(url)
            }
        }
        return out
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Log.shared.add("picker", "cancelled")
    }
}
