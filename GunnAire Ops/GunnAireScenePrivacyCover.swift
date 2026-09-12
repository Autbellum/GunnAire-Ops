import UIKit

/// Opaque, per-scene cover above app sheets. No image capture or screen access.
/// The underlying hierarchy stays mounted so its navigation and drafts survive.
@MainActor final class GunnAireScenePrivacyCover {
    private var covers: [ObjectIdentifier: UIView] = [:]
    nonisolated deinit {}

    func install(in windows: [UIWindow]) {
        for window in windows {
            let key = ObjectIdentifier(window)
            let cover: UIView
            if let existing = covers[key], existing.superview === window { cover = existing }
            else {
                let fresh = UIView(frame: window.bounds)
                fresh.backgroundColor = .systemBackground; fresh.isOpaque = true
                fresh.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                fresh.isAccessibilityElement = true; fresh.accessibilityLabel = "GunnAire Ops. Workspace hidden while inactive."
                fresh.accessibilityViewIsModal = true; fresh.accessibilityIdentifier = "GunnAireScenePrivacyCover"
                let label = UILabel()
                label.text = "GunnAire Ops"; label.font = .preferredFont(forTextStyle: .headline)
                label.adjustsFontForContentSizeCategory = true; label.translatesAutoresizingMaskIntoConstraints = false
                fresh.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: fresh.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: fresh.centerYAnchor)])
                window.addSubview(fresh); covers[key] = fresh; cover = fresh
            }
            cover.frame = window.bounds
            window.bringSubviewToFront(cover)
        }
    }
    func remove() {
        for cover in covers.values { cover.removeFromSuperview() }
        covers = [:]
    }
}
