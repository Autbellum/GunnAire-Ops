import QuickLook
import SwiftUI

struct AttachmentPreviewScreen: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL
    var onSaveEditedCopy: ((URL) -> Void)? = nil

    var body: some View {
        AttachmentQuickLookPreview(
            url: url,
            onSaveEditedCopy: onSaveEditedCopy,
            onDismiss: { dismiss() }
        )
        .ignoresSafeArea(edges: .bottom)
    }
}

struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    var onSaveEditedCopy: ((URL) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.title = url.lastPathComponent
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismissPreview)
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onSaveEditedCopy = onSaveEditedCopy
        context.coordinator.onDismiss = onDismiss
        guard let controller = uiViewController.viewControllers.first as? QLPreviewController else { return }
        controller.title = url.lastPathComponent
        controller.reloadData()
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
