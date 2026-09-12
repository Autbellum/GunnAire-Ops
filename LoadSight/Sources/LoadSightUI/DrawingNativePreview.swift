import SwiftUI
import PDFKit
import LoadSightKit

struct DrawingOverlay {
    var points: [PagePoint]
    var rectangle: Bool = false
    var pending: Bool = false
}

@MainActor
final class DrawingPreviewCoordinator: NSObject {
    var capture = false
    var onPoint: (PagePoint) -> Void = { _ in }
    weak var view: PDFView?
    #if os(macOS)
    weak var captureGesture: NSClickGestureRecognizer?
    #else
    weak var captureGesture: UITapGestureRecognizer?
    #endif
    var renderedOverlays: [PDFAnnotation] = []
    func capturePoint(_ point: CGPoint) {
        guard capture, let view, let page = view.page(for: point, nearest: false), page === view.currentPage else { return }
        let position = view.convert(point, to: page)
        onPoint(.init(x: position.x, y: position.y))
    }
    #if os(macOS)
    @objc func tapped(_ recognizer: NSClickGestureRecognizer) { capturePoint(recognizer.location(in: view)) }
    #else
    @objc func tapped(_ recognizer: UITapGestureRecognizer) { if recognizer.state == .ended { capturePoint(recognizer.location(in: view)) } }
    #endif
    func render(_ overlays: [DrawingOverlay], page: PDFPage) {
        for annotation in renderedOverlays { annotation.page?.removeAnnotation(annotation) }
        renderedOverlays = []
        let radius = max(3, page.bounds(for: .cropBox).width / 300)
        for overlay in overlays where !overlay.points.isEmpty {
            let color = overlay.pending ? PlatformColor.systemOrange : PlatformColor.systemTeal
            if overlay.rectangle, overlay.points.count == 2 {
                let a = overlay.points[0], b = overlay.points[1]
                let annotation = PDFAnnotation(bounds: CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)), forType: .square, withProperties: nil)
                annotation.color = color; add(annotation, page: page)
            } else {
                for point in overlay.points {
                    let annotation = PDFAnnotation(bounds: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2), forType: .circle, withProperties: nil)
                    annotation.color = color; annotation.interiorColor = color.withAlphaComponent(0.25); add(annotation, page: page)
                }
                for (a,b) in zip(overlay.points, overlay.points.dropFirst()) {
                    let x = min(a.x,b.x), y = min(a.y,b.y)
                    let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: max(1,abs(a.x-b.x)), height: max(1,abs(a.y-b.y))), forType: .line, withProperties: nil)
                    annotation.startPoint = CGPoint(x: a.x-x, y: a.y-y); annotation.endPoint = CGPoint(x: b.x-x, y: b.y-y)
                    annotation.color = color; let border = PDFBorder(); border.lineWidth = max(1,radius/3); annotation.border = border
                    add(annotation, page: page)
                }
            }
        }
    }
    private func add(_ annotation: PDFAnnotation, page: PDFPage) {
        annotation.shouldPrint = false
        page.addAnnotation(annotation); renderedOverlays.append(annotation)
    }
}

#if os(macOS)
private typealias PlatformColor = NSColor
struct DrawingNativePreview: NSViewRepresentable {
    var data: Data
    var kind: String
    var pageNumber: Int
    var capture: Bool
    var overlays: [DrawingOverlay]
    var onPoint: (PagePoint) -> Void
    func makeCoordinator() -> DrawingPreviewCoordinator { DrawingPreviewCoordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.document = previewDocument(data: data, kind: kind)
        view.autoScales = true; view.displayMode = .singlePage; view.displaysPageBreaks = false
        let tap = NSClickGestureRecognizer(target: context.coordinator, action: #selector(DrawingPreviewCoordinator.tapped(_:)))
        view.addGestureRecognizer(tap); context.coordinator.view = view; context.coordinator.captureGesture = tap
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.capture = capture; context.coordinator.onPoint = onPoint
        context.coordinator.captureGesture?.isEnabled = capture
        if let page = view.document?.page(at: pageNumber-1) {
            if view.currentPage !== page { view.go(to: page); view.autoScales = true }
            context.coordinator.render(overlays, page: page)
        }
    }
}
#else
private typealias PlatformColor = UIColor
struct DrawingNativePreview: UIViewRepresentable {
    var data: Data
    var kind: String
    var pageNumber: Int
    var capture: Bool
    var overlays: [DrawingOverlay]
    var onPoint: (PagePoint) -> Void
    func makeCoordinator() -> DrawingPreviewCoordinator { DrawingPreviewCoordinator() }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.document = previewDocument(data: data, kind: kind)
        view.autoScales = true; view.displayMode = .singlePage; view.displaysPageBreaks = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(DrawingPreviewCoordinator.tapped(_:)))
        tap.name = "LoadSightCapture"; view.addGestureRecognizer(tap); context.coordinator.view = view; context.coordinator.captureGesture = tap
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.capture = capture; context.coordinator.onPoint = onPoint
        context.coordinator.captureGesture?.isEnabled = capture
        if let page = view.document?.page(at: pageNumber-1) {
            if view.currentPage !== page { view.go(to: page); view.autoScales = true }
            context.coordinator.render(overlays, page: page)
        }
    }
}
#endif
