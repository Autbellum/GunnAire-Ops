import QuickLook
import SwiftUI

struct AttachmentPreviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AttachmentPreviewModel()
    @State private var retryID = UUID()

    let url: URL
    var onSaveEditedCopy: ((URL) -> Void)? = nil

    var body: some View {
        ZStack {
            if model.url == url, model.content == .quickLook {
                AttachmentQuickLookPreview(
                    url: url,
                    onSaveEditedCopy: onSaveEditedCopy,
                    onDismiss: { dismiss() }
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                NavigationStack {
                    reader
                        .navigationTitle(url.deletingPathExtension().lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                                    .keyboardShortcut(.cancelAction)
                            }
                            if case .text = model.content, model.url == url {
                                ToolbarItem(placement: .primaryAction) {
                                    ShareLink(item: url)
                                        .accessibilityLabel("Share Original File")
                                }
                            }
                        }
                }
            }
        }
        .task(id: Request(url: url, allowsEditing: onSaveEditedCopy != nil, retryID: retryID)) {
            await model.load(url: url, allowsEditing: onSaveEditedCopy != nil)
        }
        .onDisappear { model.cancel() }
    }

    private struct Request: Hashable {
        let url: URL
        let allowsEditing: Bool
        let retryID: UUID
    }

    @ViewBuilder private var reader: some View {
        if model.url != url || model.content == nil {
            ProgressView("Opening File…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .text(let text) = model.content {
            if text.isEmpty {
                ContentUnavailableView("Empty File", systemImage: "doc.text",
                    description: Text("This file has no text. You can still share the original file."))
            } else {
                ScrollView {
                    Text(verbatim: text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .accessibilityIdentifier("AttachmentTextReader")
            }
        } else {
            ContentUnavailableView {
                Label("File Unavailable", systemImage: "doc.questionmark")
            } description: {
                Text("The file couldn't be opened. Try again, or close this preview and reopen the original attachment.")
            } actions: {
                Button("Try Again") { retryID = UUID() }
            }
        }
    }
}

struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    var onSaveEditedCopy: ((URL) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        context.coordinator.controller = controller
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.title = url.lastPathComponent
        let done = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismissPreview)
        )
        let reload = UIBarButtonItem(barButtonSystemItem: .refresh,
            target: context.coordinator, action: #selector(Coordinator.reloadPreview))
        reload.accessibilityLabel = "Reload Preview"
        controller.navigationItem.leftBarButtonItems = [done, reload]
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.update(url: url, onSaveEditedCopy: onSaveEditedCopy, onDismiss: onDismiss)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            url: url,
            onSaveEditedCopy: onSaveEditedCopy,
            onDismiss: onDismiss
        )
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var url: URL
        var onSaveEditedCopy: ((URL) -> Void)?
        var onDismiss: (() -> Void)?
        weak var controller: QLPreviewController?

        init(
            url: URL,
            onSaveEditedCopy: ((URL) -> Void)?,
            onDismiss: (() -> Void)?
        ) {
            self.url = url
            self.onSaveEditedCopy = onSaveEditedCopy
            self.onDismiss = onDismiss
        }

        @objc func dismissPreview() {
            onDismiss?()
        }

        @objc func reloadPreview() {
            controller?.refreshCurrentPreviewItem()
        }

        func update(url: URL, onSaveEditedCopy: ((URL) -> Void)?, onDismiss: (() -> Void)?) {
            let changed = self.url != url
            self.url = url
            self.onSaveEditedCopy = onSaveEditedCopy
            self.onDismiss = onDismiss
            if changed {
                controller?.title = url.lastPathComponent
                controller?.reloadData()
            }
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        func previewController(
            _ controller: QLPreviewController,
            editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            onSaveEditedCopy == nil ? .disabled : .createCopy
        }

        func previewController(
            _ controller: QLPreviewController,
            didSaveEditedCopyOf previewItem: QLPreviewItem,
            at modifiedContentsURL: URL
        ) {
            onSaveEditedCopy?(modifiedContentsURL)
        }
    }
}
