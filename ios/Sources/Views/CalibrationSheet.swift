import SwiftUI
import PixelClipKit

/// Drives the motion-sensor calibration (Settings ▸ Motion Sensor ▸ Calibrate): opens a session if
/// needed (the normal connect flow, Bluetooth wake included), polls `GET /imu` at 4 Hz into
/// `CalibrationWizard`, and posts each pose when the wizard says it has been still for 3 seconds.
@MainActor @Observable
final class CalibrationController {
    private(set) var wizard = CalibrationWizard()
    private(set) var connecting = false
    /// The session couldn't be opened.
    private(set) var connectProblem: SendProblem?
    /// The wizard opened the session itself (it ends it when closed, unless sand is being tested).
    private(set) var openedSession = false
    /// Bumped on every captured pose (haptics).
    private(set) var captures = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var poseTask: Task<Void, Never>?
    /// 4 Hz.
    static let pollInterval: Duration = .milliseconds(250)

    func start(session: ClipSession) async {
        stopPolling()
        connectProblem = nil
        if !session.isConnected {
            connecting = true
            openedSession = true
            let ok = await session.connect()
            connecting = false
            guard ok else {
                connectProblem = session.problem ?? .clipNotAnswering
                return
            }
        }
        DeviceTilt.shared.start()
        do {
            let first = try await session.readIMU()
            wizard.begin(previous: first)
        } catch {
            wizard.begin(previous: nil)
            wizard.failed(error)
            return
        }
        guard wizard.problem == nil else { return }
        simulatePose(session: session, delay: .zero)
        startPolling(session: session)
    }

    /// Retry after a problem: reconnect when the connection was lost, else hold the pose again.
    func retry(session: ClipSession) async {
        if wizard.problem == .lostConnection || connectProblem != nil {
            session.markSessionEnded()
            await start(session: session)
            return
        }
        wizard.retry()
        simulatePose(session: session, delay: .zero)
        startPolling(session: session)
    }

    /// The sheet is closing. `keepSession`: a send follows (Test with Sand) and will end it.
    func stop(session: ClipSession, keepSession: Bool) {
        stopPolling()
        poseTask?.cancel()
        DeviceTilt.shared.stop()
        if session.useVirtual { Task { await session.virtualClip.setSimulatedPose(.upright) } }
        if openedSession, !keepSession, session.isConnected {
            Task { await session.endSession() }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling(session: ClipSession) {
        stopPolling()
        pollTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled, let self {
                let started = ContinuousClock.now
                do {
                    let r = try await session.client.imu()
                    misses = 0
                    guard !Task.isCancelled else { return }
                    if let action = self.wizard.ingest(r.g, at: Date()), case .capture(let step) = action {
                        await self.capture(step, session: session)
                        // Done keeps the ball live ("down is now down"); a problem waits for Retry.
                        if self.wizard.problem != nil { return }
                    }
                } catch {
                    misses += 1
                    if misses >= 3 {
                        self.wizard.failed(error)
                        return
                    }
                }
                let wait = Self.pollInterval - (ContinuousClock.now - started)
                if wait > .zero { try? await Task.sleep(for: wait) }
            }
        }
    }

    private func capture(_ step: IMUCalibrationStep, session: ClipSession) async {
        do {
            let r = try await session.client.calibrateIMU(step)
            wizard.captured(r)
            captures += 1
            if wizard.step == .done {
                session.imu = try? await session.client.imu()
            }
            simulatePose(session: session, delay: .milliseconds(1400))
        } catch {
            wizard.failed(error)
        }
    }

    /// The simulator has no accelerometer: the virtual clip is "turned" into each step's pose a moment
    /// after it starts, as a person would (a device in virtual mode uses its own tilt instead).
    private func simulatePose(session: ClipSession, delay: Duration) {
        guard session.useVirtual, !DeviceTilt.shared.isAvailable else { return }
        let pose: IMUVector = wizard.step == .faceUp ? .faceUp : .upright
        poseTask?.cancel()
        poseTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await session.virtualClip.setSimulatedPose(pose)
        }
    }
}

/// The three-step calibration sheet: upright → flat on its back → what changed, with a live ball
/// showing the clip's gravity on a clip outline.
struct CalibrationSheet: View {
    @Environment(ClipSession.self) private var session
    @Environment(Sender.self) private var sender
    @Environment(\.dismiss) private var dismiss
    @State private var controller = CalibrationController()
    @State private var testingSand = false
    @State private var showTechnical = false

    private var wizard: CalibrationWizard { controller.wizard }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    StepDots(step: wizard.step)
                        .padding(.top, 4)
                    if controller.connecting {
                        connectingCard
                    } else if let p = controller.connectProblem {
                        ProblemCard(problem: p)
                    } else {
                        VStack(spacing: 10) {
                            GravityBall(g: wizard.latest, target: target, done: wizard.step == .done)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 12)
                            Text(wizard.step == .done ? "Live: the ball is where PixelClip now thinks down is."
                                                      : "Live: the ball is where PixelClip thinks down is.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if wizard.step == .done { doneContent } else { stepContent }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Calibrate Motion Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: wizard.step == .done ? .confirmationAction : .cancellationAction) {
                    Button(wizard.step == .done ? "Done" : "Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomButton }
        }
        .presentationDetents([.large])
        .task { await controller.start(session: session) }
        .onDisappear { controller.stop(session: session, keepSession: testingSand) }
        .sensoryFeedback(.success, trigger: controller.captures)
        .sensoryFeedback(.error, trigger: wizard.problem) { _, p in p != nil }
        .sensoryFeedback(.selection, trigger: countdown)
        .animation(.smooth(duration: 0.3), value: wizard.step)
        .animation(.smooth(duration: 0.2), value: wizard.phase)
    }

    private var countdown: Int? { if case .counting(let n) = wizard.phase { n } else { nil } }

    /// Where the ball should settle for this step.
    private var target: IMUVector? {
        switch wizard.step {
        case .upright: .upright
        case .faceUp: .faceUp
        case .done: nil
        }
    }

    private var connectingCard: some View {
        HStack(spacing: 14) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text("Connecting to \(session.displayName)…").font(.headline)
                Text(session.stateLine).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    // MARK: Steps 1–2

    @ViewBuilder private var stepContent: some View {
        VStack(spacing: 8) {
            Text(wizard.step == .upright ? "Hold PixelClip upright, screen facing you, like it’s in hair" : "Lay it flat on its back, screen up")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(wizard.step == .upright ? "Keep it level and still for three seconds."
                                         : "On a table is easiest. Keep it still for three seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        if let p = wizard.problem {
            CalibrationProblemCard(problem: p, step: wizard.step)
        } else {
            phaseLine
        }
    }

    @ViewBuilder private var phaseLine: some View {
        HStack(spacing: 12) {
            switch wizard.phase {
            case .holding where wizard.needsTurning:
                Image(systemName: "rotate.3d").foregroundStyle(.tint)
                Text(wizard.step == .faceUp ? "Now lay it on its back…" : "Now stand it upright…").font(.headline)
            case .holding:
                Image(systemName: "hand.raised").foregroundStyle(.secondary)
                Text("Waiting until it’s still…").foregroundStyle(.secondary)
            case .counting(let n):
                Text("\(n)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText(countsDown: true))
                Text("Hold still…").font(.headline)
            case .measuring:
                ProgressView()
                Text("Measuring…").font(.headline)
            case .problem:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 3

    @ViewBuilder private var doneContent: some View {
        let change = wizard.change
        VStack(spacing: 8) {
            Label(change?.headline ?? "Down is now down", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .symbolRenderingMode(.multicolor)
            Text(change?.detail ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 12) {
            Text("Stored on \(session.displayName): sand, snow, water and balls now fall toward the floor when it’s in your hair.")
                .font(.subheadline)
            DisclosureGroup("Axis map", isExpanded: $showTechnical) {
                Text(Self.matrix(wizard.result))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .textSelection(.enabled)
            }
            .font(.subheadline)
        }
        .card()
    }

    static func matrix(_ m: IMUAxisMap?) -> String {
        guard let m else { return "–" }
        let names = ["x (right)", "y (down)", "z (out)"]
        let chip = ["X", "Y", "Z"]
        return m.rows.enumerated().map { i, r in
            let j = r.firstIndex { $0 != 0 } ?? 0
            return "\(names[i]) = \(r[j] < 0 ? "−" : "+")chip \(chip[j])"
        }.joined(separator: "\n")
    }

    // MARK: Buttons

    @ViewBuilder private var bottomButton: some View {
        Group {
            if wizard.step == .done {
                Button {
                    testSand()
                } label: {
                    Label("Test with Sand", systemImage: "hourglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Color.onAccent)
            } else if let p = wizard.problem, !p.isFinal {
                Button {
                    Task { await controller.retry(session: session) }
                } label: {
                    Label(p.retryLabel, systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Color.onAccent)
            } else if controller.connectProblem != nil {
                Button {
                    Task { await controller.retry(session: session) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Color.onAccent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// Sand (default palette) goes on the clip; "Sent · Undo" shows once this sheet has gone.
    private func testSand() {
        testingSand = true
        dismiss()
        sender.sendNow(.scene("sand", params: SceneLook.params(scene: "sand", palette: nil)), title: "Sand")
    }
}

/// 1 · 2 · 3 with the step names.
private struct StepDots: View {
    let step: CalibrationWizard.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CalibrationWizard.Step.allCases, id: \.self) { s in
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(s <= step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        if s < step {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color.onAccent)
                        } else {
                            Text("\(s.rawValue + 1)").font(.caption.bold())
                                .foregroundStyle(s == step ? Color.onAccent : .secondary)
                        }
                    }
                    .frame(width: 26, height: 26)
                    Text(name(s)).font(.caption).foregroundStyle(s == step ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of 3: \(name(step))")
    }

    private func name(_ s: CalibrationWizard.Step) -> String {
        switch s {
        case .upright: "Upright"
        case .faceUp: "Flat"
        case .done: "Done"
        }
    }
}

/// A small ball on a clip outline: where gravity points in the clip's own frame (x right, y down; a
/// reading into the glass shrinks it to the centre). The ring marks where it should settle.
private struct GravityBall: View {
    let g: IMUVector?
    let target: IMUVector?
    let done: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let inset: CGFloat = 26
            let rx = w / 2 - inset, ry = h / 2 - inset
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous)
                    .fill(Color.black)
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 2)
                // The hair-clip spring along the top edge, so "upright" reads at a glance.
                Capsule().fill(Color.secondary.opacity(0.45))
                    .frame(width: w * 0.42, height: 6)
                    .position(x: w / 2, y: -9)
                if let target {
                    Circle().strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .frame(width: 34, height: 34)
                        .position(point(target, w: w, h: h, rx: rx, ry: ry))
                }
                if let g {
                    let depth = max(0.45, 1 - abs(g.z) * 0.5)
                    Circle()
                        .fill(done ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(red: 1, green: 0.75, blue: 0.2)))
                        .shadow(color: .orange.opacity(0.6), radius: 8)
                        .frame(width: 26 * depth, height: 26 * depth)
                        .position(point(g, w: w, h: h, rx: rx, ry: ry))
                        .animation(.interactiveSpring(duration: 0.25), value: g)
                }
            }
        }
        .aspectRatio(536.0 / 240.0, contentMode: .fit)
        .padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live gravity")
        .accessibilityValue(g.map { String(format: "x %.2f, y %.2f, z %.2f", $0.x, $0.y, $0.z) } ?? "No reading yet")
    }

    private func point(_ v: IMUVector, w: CGFloat, h: CGFloat, rx: CGFloat, ry: CGFloat) -> CGPoint {
        CGPoint(x: w / 2 + CGFloat(max(-1, min(1, v.x))) * rx, y: h / 2 + CGFloat(max(-1, min(1, v.y))) * ry)
    }
}

private struct CalibrationProblemCard: View {
    let problem: CalibrationProblem
    let step: CalibrationWizard.Step

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: problem.isFinal ? "sensor" : "exclamationmark.triangle", tint: .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.title).font(.headline)
                Text(problem.message(for: step)).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}
