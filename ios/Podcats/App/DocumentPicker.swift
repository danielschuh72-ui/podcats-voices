import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iOS file picker, used directly (UIKit) and asking for copies: the files it hands back are already inside the
/// app, so nothing depends on permission to read someone else's folder. SwiftUI's own `.fileImporter` was used first
/// and, on the iPhone, never reported what was picked.
struct DocumentPicker: UIViewControllerRepresentable {
    let onDone: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { return Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .data lets any file be chosen: a script without an extension, or one iOS files under an odd type, is not greyed out
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .text, .json, .zip, .data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        if let dir = Demo.pickerDirectory { picker.directoryURL = dir }
        Log.shared.add("picker", "opened")
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: ([URL]) -> Void
        init(onDone: @escaping ([URL]) -> Void) { self.onDone = onDone }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Log.shared.add("picker", "picked \(urls.count): " + urls.map { $0.lastPathComponent }.joined(separator: ", "))
            onDone(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.shared.add("picker", "cancelled")
            onDone([])
        }
    }
}
