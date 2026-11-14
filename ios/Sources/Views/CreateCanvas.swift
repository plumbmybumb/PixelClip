import PencilKit
import SwiftUI
import UIKit
import PixelClipKit

/// The 536×240 drawing surface. A UIScrollView zooms it (two fingers pinch and pan; one finger
/// draws) and always settles on an integer number of device pixels per canvas pixel, so pixel art
/// stays crisp. Layers, bottom to top: background, paint (fill/pixel), onion skins, PencilKit
/// ink, overlays (text/stickers), pixel grid, the custom-tool touch layer.
struct CreateCanvasView: UIViewRepresentable {
    let model: CreateDrawModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> CanvasContainerView {
        let v = CanvasContainerView()
        v.canvas.delegate = context.coordinator
        v.touches.model = model
        v.onZoomStep = { [weak model] label in model?.zoomLabel = label }
        return v
    }

    func updateUIView(_ v: CanvasContainerView, context: Context) {
        let c = context.coordinator
        c.model = model
        v.touches.model = model
        // Reading these registers observation, so SwiftUI calls us again when they change.
        let revision = model.canvasRevision
        let frameID = model.currentFrame.id
        v.background.backgroundColor = model.background.uiColor
        v.setLayers(model.layers)
        v.setTool(model.tool, pkTool: model.pkTool, pixelCell: model.pixelCell)
        v.setSelection(model.selectedOverlay.map { FrameCompositor.bounds(of: $0, providers: CreateStickers.providers) })
        if c.revision != revision || c.frameID != frameID {
            c.revision = revision
            c.frameID = frameID
            c.applying = true
            v.canvas.drawing = model.currentDrawing
            c.applying = false
        }
    }

    @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate {
        var model: CreateDrawModel
        var revision = -1
        var frameID: UUID?
        var applying = false
        init(model: CreateDrawModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applying else { return }
            model.inkChanged(canvasView.drawing)
        }
    }
}

final class CanvasContainerView: UIView, UIScrollViewDelegate {
    let scroll = UIScrollView()
    let content = UIView(frame: CGRect(origin: .zero, size: ClipCanvas.size))
    let background = UIView()
    let pixels = UIImageView()
    let onionPrev = UIImageView()
    let onionNext = UIImageView()
    let canvas = PKCanvasView()
    let overlays = UIImageView()
    let grid = PixelGridView()
    let touches = ToolTouchView()
    private let selectionLayer = CAShapeLayer()
    private var lastStep = 0
    /// The fitted step the zoom was last laid out for (0 before the first layout).
    private var lastFit = 0
    var onZoomStep: ((String) -> Void)?

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    /// Device pixels per canvas pixel at the fitted zoom: the largest whole step that fits both ways
    /// (width-limited in portrait; in landscape the rail and frame strip share the screen).
    private var fitStep: Int { CanvasZoom.fitStep(in: bounds.size, scale: screenScale) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bouncesZoom = true
        scroll.alwaysBounceHorizontal = false
        scroll.delaysContentTouches = false
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2     // one finger draws
        addSubview(scroll)
        scroll.addSubview(content)

        for v in [background, pixels, onionPrev, onionNext, overlays, grid, touches] as [UIView] {
            v.frame = content.bounds
        }
        for iv in [pixels, onionPrev, onionNext, overlays] {
            iv.layer.magnificationFilter = .nearest
            iv.isUserInteractionEnabled = false
        }
        onionPrev.alpha = 0.32
        onionNext.alpha = 0.24
        content.addSubview(background)
        content.addSubview(pixels)
        content.addSubview(onionPrev)
        content.addSubview(onionNext)

        canvas.frame = content.bounds
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.overrideUserInterfaceStyle = .light   // inks render exactly as picked (no dark-mode inversion)
        canvas.contentInsetAdjustmentBehavior = .never
        content.addSubview(canvas)
        content.addSubview(overlays)
        grid.isUserInteractionEnabled = false
        grid.isHidden = true
        content.addSubview(grid)
        content.addSubview(touches)

        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = UIColor.white.cgColor
        selectionLayer.lineDashPattern = [4, 3]
        content.layer.addSublayer(selectionLayer)
        content.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        isAccessibilityElement = true
        accessibilityLabel = "Drawing canvas, 536 by 240 pixels"
        accessibilityHint = "Draw with one finger. Pinch with two fingers to zoom."
    }

    required init?(coder: NSCoder) { fatalError() }

    /// iOS 26 can swipe back from anywhere in the content, which would steal one-finger strokes.
    /// While the canvas is on screen, the navigation controller's pop gestures are off (the back
    /// button still works).
    private weak var navigation: UINavigationController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            var r: UIResponder? = self
            while let next = r?.next, !(next is UINavigationController) { r = next }
            navigation = r?.next as? UINavigationController
            navigation?.interactiveContentPopGestureRecognizer?.isEnabled = false
            navigation?.interactivePopGestureRecognizer?.isEnabled = false
        } else {
            navigation?.interactiveContentPopGestureRecognizer?.isEnabled = true
            navigation?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let s = screenScale
        let fit = fitStep
        if fit != lastFit {
            // First layout: fit. A rotation (new size): keep the zoom relative to the fit and keep the
            // same point of the drawing in the middle of the view.
            let mid = lastFit == 0 ? nil : visibleCenter()
            let step = lastFit == 0 ? fit : CanvasZoom.carriedStep(lastStep, from: lastFit, to: fit)
            scroll.frame = bounds
            scroll.minimumZoomScale = CGFloat(fit) / s
            scroll.maximumZoomScale = CGFloat(fit * CanvasZoom.maxFactor) / s
            scroll.zoomScale = CGFloat(step) / s
            lastFit = fit
            lastStep = step
            centerContent()
            if let mid { scroll(toCenter: mid) }
            onZoomStep?(CanvasZoom.label(step: step, fit: fit))
        } else {
            scroll.frame = bounds
            centerContent()
        }
        updateHairlines()
    }

    /// The canvas point in the middle of the view.
    private func visibleCenter() -> CGPoint {
        let z = max(0.0001, scroll.zoomScale)
        return CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / z,
                       y: (scroll.contentOffset.y + scroll.bounds.height / 2) / z)
    }

    private func scroll(toCenter p: CGPoint) {
        let z = scroll.zoomScale
        let inset = scroll.contentInset
        let maxX = max(-inset.left, scroll.contentSize.width + inset.right - scroll.bounds.width)
        let maxY = max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        let x = min(max(p.x * z - scroll.bounds.width / 2, -inset.left), maxX)
        let y = min(max(p.y * z - scroll.bounds.height / 2, -inset.top), maxY)
        scroll.contentOffset = CGPoint(x: x, y: y)
    }

    // MARK: Model → view

    func setLayers(_ l: CanvasLayers) {
        pixels.image = l.pixels.map { UIImage(cgImage: $0) }
        overlays.image = l.overlays.map { UIImage(cgImage: $0) }
        onionPrev.image = l.onionPrev.map { UIImage(cgImage: $0) }
        onionNext.image = l.onionNext.map { UIImage(cgImage: $0) }
    }

    func setTool(_ tool: DrawTool, pkTool: PKTool, pixelCell: Int) {
        canvas.tool = pkTool
        canvas.isUserInteractionEnabled = tool.isInk
        touches.isUserInteractionEnabled = !tool.isInk
        touches.tool = tool
        grid.cell = pixelCell
        grid.isHidden = tool != .pixel
    }

    func setSelection(_ rect: CGRect?) {
        selectionLayer.path = rect.map { UIBezierPath(rect: $0).cgPath }
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateHairlines()
    }

    /// Settle on the nearest whole device-pixel step, springing from where the pinch left it.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let s = screenScale
        let step = min(max(Int((scale * s).rounded()), fitStep), fitStep * CanvasZoom.maxFactor)
        let target = CGFloat(step) / s
        if abs(target - scale) > 0.0001 {
            UIView.animate(springDuration: 0.35, bounce: 0) { scrollView.zoomScale = target } completion: { _ in
                self.centerContent()
            }
        }
        if step != lastStep {
            lastStep = step
            UISelectionFeedbackGenerator().selectionChanged()
        }
        onZoomStep?(CanvasZoom.label(step: step, fit: fitStep))
    }

    func resetZoom() {
        UIView.animate(springDuration: 0.35, bounce: 0) { self.scroll.zoomScale = self.scroll.minimumZoomScale }
        lastStep = fitStep
        onZoomStep?("Fit")
    }

    private func centerContent() {
        let size = CGSize(width: CGFloat(ClipCanvas.width) * scroll.zoomScale, height: CGFloat(ClipCanvas.height) * scroll.zoomScale)
        let dx = max(0, (scroll.bounds.width - size.width) / 2)
        let dy = max(0, (scroll.bounds.height - size.height) / 2)
        // Whole device pixels, so canvas pixels land on screen pixels.
        let s = screenScale
        scroll.contentInset = UIEdgeInsets(top: (dy * s).rounded() / s, left: (dx * s).rounded() / s, bottom: 0, right: 0)
    }

    private func updateHairlines() {
        let px = 1 / max(0.0001, scroll.zoomScale * screenScale)
        selectionLayer.lineWidth = 1.5 * px
        selectionLayer.lineDashPattern = [NSNumber(value: Double(5 * px)), NSNumber(value: Double(4 * px))]
        content.layer.borderWidth = px
        grid.hairline = px
        grid.isZoomedEnough = scroll.zoomScale * screenScale * CGFloat(grid.cell) >= 6
    }
}

/// Thin lines on the pixel-pen grid.
final class PixelGridView: UIView {
    var cell = 4 { didSet { if cell != oldValue { setNeedsDisplay() } } }
    var hairline: CGFloat = 0.5 { didSet { if hairline != oldValue { setNeedsDisplay() } } }
    var isZoomedEnough = true { didSet { if isZoomedEnough != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard isZoomedEnough, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.13).cgColor)
        ctx.setLineWidth(hairline)
        var x = 0
        while x <= ClipCanvas.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: ClipCanvas.height)); x += cell }
        var y = 0
        while y <= ClipCanvas.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: ClipCanvas.width, y: y)); y += cell }
        ctx.strokePath()
    }
}

/// Fill, pixel pen, shapes, text, stickers and move. Responds on touch-down (pixel pen paints the
/// first cell immediately); a second finger hands over to the scroll view's pinch.
final class ToolTouchView: UIView {
    weak var model: CreateDrawModel?
    var tool: DrawTool = .pen
    private var start: CGPoint?
    private var last: CGPoint?
    private var moving = false
    private let shapePreview = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        shapePreview.fillColor = UIColor.clear.cgColor
        shapePreview.lineCap = .round
        shapePreview.lineJoin = .round
        layer.addSublayer(shapePreview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let model else { return }
        let p = t.location(in: self)
        start = p; last = p
        switch tool {
        case .pixel: model.beginPixels(at: p)
        case .move: moving = model.beginMove(at: p)
        default: break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let model, let s = start, let l = last else { return }
        let p = t.location(in: self)
        switch tool {
        case .pixel: model.continuePixels(from: l, to: p)
        case .shape: drawShapePreview(from: s, to: p, model: model)
        case .move where moving: model.moveSelection(by: CGSize(width: p.x - l.x, height: p.y - l.y))
        default: break
        }
        last = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let model, let s = start else { return }
        let p = t.location(in: self)
        switch tool {
        case .fill: model.fill(at: p)
        case .pixel: model.endPixels()
        case .shape: model.addShape(from: s, to: p)
        case .text: model.pendingTextPoint = p
        case .sticker: model.placeSticker(at: p)
        case .move where moving: model.endMove()
        default: break
        }
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if tool == .pixel { model?.endPixels() }
        if tool == .move, moving { model?.endMove() }
        finish()
    }

    private func finish() {
        start = nil; last = nil; moving = false
        shapePreview.path = nil
    }

    private func drawShapePreview(from a: CGPoint, to b: CGPoint, model: CreateDrawModel) {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let path: UIBezierPath
        switch model.shapeKind {
        case .line: path = UIBezierPath(); path.move(to: a); path.addLine(to: b)
        case .rect: path = UIBezierPath(rect: r)
        case .ellipse: path = UIBezierPath(ovalIn: r)
        }
        let filled = model.shapeFilled && model.shapeKind != .line
        shapePreview.path = path.cgPath
        shapePreview.strokeColor = model.color.uiColor.cgColor
        shapePreview.fillColor = filled ? model.color.uiColor.cgColor : UIColor.clear.cgColor
        shapePreview.lineWidth = filled ? 0 : model.width
    }
}
