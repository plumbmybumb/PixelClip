import SwiftUI
import PixelClipKit

/// The locked 536:240 crop frame (Send's crop screen). The picture moves under it with 1:1 tracking
/// (pinch zooms around the fingers), keeps its momentum when flung, rubber-bands past the zoom limits
/// and snaps to right angles. Inside the frame you see the encoder's output; outside, the dimmed
/// source. The frame is outlined in the accent with "THE CLIP SEES THIS" in its corner.
struct CropCanvas: View {
    @Bindable var model: EditorModel
    /// Space between the frame and the canvas's sides.
    var inset: CGFloat = 0
    @State private var base: CropTransform?
    @State private var translation: CGSize = .zero
    @State private var magnification: CGFloat = 1
    @State private var anchor: UnitPoint = .center
    @State private var rotation: Angle = .zero
    @State private var snaps = 0
    @State private var active: Set<String> = []
    @State private var releaseVelocity: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let frameW = min(geo.size.width - 2 * inset, (geo.size.height - 40) * ClipCanvas.aspect)
            let frameH = frameW / ClipCanvas.aspect
            let k = frameW / Double(ClipCanvas.width)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let t = model.transform
            ZStack {
                if let src = model.posterSource {
                    Image(decorative: src, scale: 1)
                        .resizable()
                        .frame(width: Double(src.width) * t.scale * k, height: Double(src.height) * t.scale * k)
                        .rotationEffect(.radians(t.rotation))
                        .position(x: center.x + t.offsetX * k, y: center.y + t.offsetY * k)
                        .opacity(0.3)
                        .accessibilityHidden(true)
                }
                ClipScreenPreview(frames: model.preview, glow: false, bezel: false, accessibilityLabel: "Preview of \(model.name) on the clip")
                    .frame(width: frameW, height: frameH)
                    .position(center)
                    .allowsHitTesting(false)
                Grid3x3()
                    .stroke(.white.opacity(0.35), lineWidth: 0.5)
                    .frame(width: frameW, height: frameH)
                    .position(center)
                    .opacity(model.isInteracting ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: model.isInteracting)
                    .allowsHitTesting(false)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                    Text("THE CLIP SEES THIS")
                        .font(.caption2.weight(.medium))
                        .tracking(0.4)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: .capsule)
                        .padding(8)
                        .opacity(model.isInteracting ? 0 : 1)
                        .animation(.easeOut(duration: 0.2), value: model.isInteracting)
                        .accessibilityHidden(true)
                }
                .frame(width: frameW, height: frameH)
                .position(center)
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(.rect)
            .gesture(gestures(k: k, size: geo.size, center: center))
            .onTapGesture(count: 2) { toggleFitFill() }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Pinch, drag or rotate to crop. Double-tap to switch between fit and fill.")
            .accessibilityAction(named: "Fill") { CropAnimator.shared.animate(model, to: CropTransform(scale: model.fillScale)) }
            .accessibilityAction(named: "Fit") { CropAnimator.shared.animate(model, to: CropTransform(scale: model.fitScale)) }
        }
        .sensoryFeedback(.alignment, trigger: snaps)
    }

    // MARK: Gestures

    private func gestures(k: Double, size: CGSize, center: CGPoint) -> some Gesture {
        let drag = DragGesture(minimumDistance: 1)
            .onChanged { v in
                begin("drag")
                translation = v.translation
                apply(k: k, size: size, center: center)
            }
            .onEnded { v in
                translation = v.translation
                apply(k: k, size: size, center: center)
                releaseVelocity = CGSize(width: v.velocity.width / k, height: v.velocity.height / k)
                end("drag")
            }
        let pinch = MagnifyGesture()
            .onChanged { v in
                begin("pinch")
                magnification = v.magnification
                anchor = v.startAnchor
                apply(k: k, size: size, center: center)
            }
            .onEnded { _ in end("pinch") }
        let rotate = RotateGesture()
            .onChanged { v in
                begin("rotate")
                rotation = v.rotation
                apply(k: k, size: size, center: center)
            }
            .onEnded { _ in end("rotate") }
        return SimultaneousGesture(drag, SimultaneousGesture(pinch, rotate))
    }

    private func begin(_ gesture: String) {
        active.insert(gesture)
        guard base == nil else { return }
        releaseVelocity = .zero
        CropAnimator.shared.stop()   // grab it mid-flight: start from where it is now
        base = model.transform
        translation = .zero; magnification = 1; rotation = .zero
        model.isInteracting = true
    }

    /// transform = base, zoomed about the fingers, translated, rotated.
    private func apply(k: Double, size: CGSize, center: CGPoint) {
        guard let base else { return }
        let lo = model.fitScale * 0.5, hi = model.fillScale * 8
        let raw = base.scale * magnification
        let s = rubberband(raw, lo, hi)
        let ratio = s / base.scale
        let ax = (anchor.x * size.width - center.x) / k
        let ay = (anchor.y * size.height - center.y) / k
        var t = base
        t.scale = s
        t.offsetX = ax + (base.offsetX - ax) * ratio + translation.width / k
        t.offsetY = ay + (base.offsetY - ay) * ratio + translation.height / k
        t.rotation = base.rotation + rotation.radians
        // Past the limits the picture follows less and less.
        let lim = CropAnimator.offsetLimits(t, source: model.sourceSize)
        t.offsetX = rubberband(t.offsetX, lim.x.lowerBound, lim.x.upperBound, dimension: Double(ClipCanvas.width))
        t.offsetY = rubberband(t.offsetY, lim.y.lowerBound, lim.y.upperBound, dimension: Double(ClipCanvas.height))
        model.transform = t
    }

    /// Settle only once every finger is up.
    private func end(_ gesture: String) {
        active.remove(gesture)
        if active.isEmpty { finish(velocity: releaseVelocity) }
    }

    private func finish(velocity: CGSize) {
        guard base != nil else { return }
        base = nil
        var target = model.transform
        let lo = model.fitScale * 0.5, hi = model.fillScale * 8
        target.scale = min(max(target.scale, lo), hi)
        let quarter = Double.pi / 2
        let nearest = (target.rotation / quarter).rounded() * quarter
        if abs(nearest - target.rotation) < 0.07 && nearest != target.rotation {
            target.rotation = nearest
            snaps += 1
        }
        CropAnimator.shared.settle(model, to: target, velocity: velocity) { [model] in
            model.isInteracting = false
        }
    }

    private func toggleFitFill() {
        let fill = model.fillScale, fit = model.fitScale
        let goFit = abs(model.transform.scale - fill) < abs(model.transform.scale - fit)
        CropAnimator.shared.animate(model, to: CropTransform(scale: goFit ? fit : fill))
    }

    /// Soft limits: past a bound the value follows less and less (apple-design §9).
    private func rubberband(_ v: Double, _ lo: Double, _ hi: Double, dimension: Double? = nil) -> Double {
        func band(_ over: Double, _ dim: Double) -> Double { (over * dim * 0.55) / (dim + 0.55 * abs(over)) }
        if v < lo { return lo - band(lo - v, dimension ?? lo) }
        if v > hi { return hi + band(v - hi, dimension ?? hi) }
        return v
    }
}

/// Rule-of-thirds grid.
struct Grid3x3: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = r.minX + r.width * Double(i) / 3, y = r.minY + r.height * Double(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

/// Drives the crop transform frame by frame so every intermediate state goes through the real
/// renderer (a SwiftUI animation would only interpolate the view, not the model).
/// Momentum uses Apple's exponential deceleration; settling uses a critically damped spring.
@MainActor
final class CropAnimator {
    static let shared = CropAnimator()
    private var task: Task<Void, Never>?

    func stop() { task?.cancel(); task = nil }

    /// Critically damped spring (damping 1.0, response 0.35 s) from the current value.
    func animate(_ model: EditorModel, to target: CropTransform, response: Double = 0.35, completion: (() -> Void)? = nil) {
        stop()
        let from = model.transform
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        task = Task { @MainActor in
            if reduceMotion { model.transform = target; completion?(); return }
            let omega = 2 * Double.pi / response
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let e = (1 + omega * t) * exp(-omega * t)
                if e < 0.002 { model.transform = target; break }
                model.transform = CropTransform(scale: target.scale + (from.scale - target.scale) * e,
                                                offsetX: target.offsetX + (from.offsetX - target.offsetX) * e,
                                                offsetY: target.offsetY + (from.offsetY - target.offsetY) * e,
                                                rotation: target.rotation + (from.rotation - target.rotation) * e)
                try? await Task.sleep(for: .milliseconds(8))
            }
            if !Task.isCancelled { completion?() }
        }
    }

    /// Carry the fling's velocity (output px/s), decelerate, then spring scale/rotation home and
    /// keep at least part of the picture inside the frame.
    func settle(_ model: EditorModel, to target: CropTransform, velocity: CGSize, completion: @escaping () -> Void) {
        stop()
        let speed = hypot(velocity.width, velocity.height)
        guard speed > 60, !UIAccessibility.isReduceMotionEnabled else {
            animate(model, to: contained(target, model), completion: completion)
            return
        }
        task = Task { @MainActor in
            var v = velocity
            var last = Date()
            let rate = 0.995   // per millisecond
            while !Task.isCancelled && hypot(v.width, v.height) > 20 {
                try? await Task.sleep(for: .milliseconds(8))
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                var t = model.transform
                t.offsetX += v.width * dt
                t.offsetY += v.height * dt
                model.transform = t
                let decay = pow(rate, dt * 1000)
                v.width *= decay; v.height *= decay
            }
            guard !Task.isCancelled else { return }
            var final = model.transform
            final.scale = target.scale
            final.rotation = target.rotation
            self.animate(model, to: self.contained(final, model), completion: completion)
        }
    }

    /// Photos-style limits: a picture that can cover the frame must cover it (no accidental black
    /// gaps); a smaller one (fit) must stay inside it. Rotations off the right angles only keep
    /// the centre inside the frame.
    static func offsetLimits(_ t: CropTransform, source: CGSize) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let fw = Double(ClipCanvas.width), fh = Double(ClipCanvas.height)
        let quarter = (t.rotation / (.pi / 2)).rounded()
        guard abs(t.rotation - quarter * .pi / 2) < 0.001 else { return (-fw / 2...fw / 2, -fh / 2...fh / 2) }
        let swapped = Int(abs(quarter)) % 2 == 1
        let iw = (swapped ? source.height : source.width) * t.scale
        let ih = (swapped ? source.width : source.height) * t.scale
        let mx = abs(iw - fw) / 2, my = abs(ih - fh) / 2
        return (-mx...mx, -my...my)
    }

    private func contained(_ t: CropTransform, _ model: EditorModel) -> CropTransform {
        var t = t
        let lim = Self.offsetLimits(t, source: model.sourceSize)
        t.offsetX = min(max(t.offsetX, lim.x.lowerBound), lim.x.upperBound)
        t.offsetY = min(max(t.offsetY, lim.y.lowerBound), lim.y.upperBound)
        return t
    }
}
