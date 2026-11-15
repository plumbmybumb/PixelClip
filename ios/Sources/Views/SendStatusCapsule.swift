import SwiftUI
import PixelClipKit

/// The send in plain words, in a Liquid Glass capsule floating at the top of Home and the playlist:
/// "Looking for the clip…", "Waking the clip…", "Connecting…", "Sending 2 of 5 · 40%", "Sent" (with
/// Undo), "Can't reach the clip — will retry" (with Retry and Cancel). It shows whenever a send is
/// running or waiting for the clip, and for a few seconds after one went through (`Sender.stage`).
/// It replaces the toast for sends; removals keep their toast.
struct SendStatusCapsule: View {
    @Environment(Sender.self) private var sender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let stage = sender.stage {
                capsule(stage)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Z2.spring, value: sender.stage)
    }

    private func capsule(_ stage: Sender.Stage) -> some View {
        HStack(spacing: 10) {
            icon(stage)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(stage))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Z2.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("sendStatusTitle")
                if let detail = Self.detail(stage, waiting: !sender.isSending, failure: sender.failure) {
                    Text(detail).font(.caption).foregroundStyle(Z2.secondary).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            buttons(stage)
        }
        .padding(.leading, 16)
        .padding(.trailing, hasButtons(stage) ? 6 : 16)
        .padding(.vertical, 6)
        .frame(minHeight: 50)
        // Tinted enough to stay legible over the screen's own text.
        .glassEffect(.regular.tint(Z2.sheet.opacity(0.82)), in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sendStatus")
    }

    @ViewBuilder
    private func icon(_ stage: Sender.Stage) -> some View {
        switch stage {
        case .looking, .waking, .connecting, .sending:
            if reduceMotion {
                Image(systemName: "ellipsis.circle").foregroundStyle(Color.accentColor)
            } else {
                ProgressView().controlSize(.small).tint(Color.accentColor)
            }
        case .uploading(_, _, let f):
            ZStack {
                Circle().stroke(Z2.secondary.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, min(1, f)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(2)
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Z2.nearby)
        case .waiting:
            Image(systemName: "clock").foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func hasButtons(_ stage: Sender.Stage) -> Bool {
        switch stage {
        case .sent(.sent): NowOnClip.shared.canUndo
        case .looking: !sender.isSending
        case .waiting, .failed: true
        default: false
        }
    }

    @ViewBuilder
    private func buttons(_ stage: Sender.Stage) -> some View {
        switch stage {
        case .sent(.sent) where NowOnClip.shared.canUndo:
            pill("Undo", id: "sendStatusUndo", hint: "Puts back what was on the clip before") {
                sender.dismissSent()
                sender.undo()
            }
        case .waiting where !sender.isSending, .looking where !sender.isSending:
            round("arrow.clockwise", label: "Retry", id: "sendStatusRetry", hint: "Tries to reach the clip now") { sender.retryNow() }
            round("xmark", label: "Cancel", id: "sendStatusCancel", hint: "Stops waiting; the changes go with the next send", prominent: false) {
                sender.cancelPending()
            }
        case .failed where sender.failure == .clipPasswordReset:
            pill("Set up again", id: "sendStatusSetUpAgain", hint: "Gives the clip a new Wi‑Fi password, then sends") { sender.setUpAgain() }
            round("xmark", label: "Close", id: "sendStatusCancel", hint: "Hides this message", prominent: false) { sender.dismissFailure() }
        case .failed:
            round("arrow.clockwise", label: "Retry", id: "sendStatusRetry", hint: "Tries the send again") { sender.retryNow() }
            round("xmark", label: "Close", id: "sendStatusCancel", hint: "Hides this message", prominent: false) { sender.dismissFailure() }
        default:
            EmptyView()
        }
    }

    /// A round icon button (Retry, Cancel) so the words keep the room.
    private func round(_ systemImage: String, label: String, id: String, hint: String, prominent: Bool = true,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(prominent ? Color.accentColor : Z2.secondary)
                .frame(width: 38, height: 38)
                .background(prominent ? Color.accentColor.opacity(0.16) : Color.clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(Z2Press(scale: 0.92))
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    private func pill(_ title: String, id: String, hint: String, prominent: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(prominent ? .bold : .medium))
                .foregroundStyle(prominent ? Color.accentColor : Z2.secondary)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 38)
                .contentShape(.capsule)
        }
        .buttonStyle(Z2Press(scale: 0.94))
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    // MARK: Words

    static func title(_ stage: Sender.Stage) -> String {
        switch stage {
        case .looking: "Looking for the clip…"
        case .waking: "Waking the clip…"
        case .connecting: "Connecting…"
        case .uploading(let i, let n, let f): "Sending \(i) of \(n) · \(Int((f * 100).rounded()))%"
        case .sending: "Sending…"
        case .sent(.playlist): "Added to the playlist"
        case .sent: "Sent"
        case .waiting: "Can’t reach the clip — will retry"
        case .failed(let t): t
        }
    }

    static func detail(_ stage: Sender.Stage, waiting: Bool, failure: SendProblem? = nil) -> String? {
        switch stage {
        case .waiting: "Looking again every 10 s"
        case .looking where waiting: "The send waits for it"
        case .failed where failure == .clipPasswordReset || failure == .clipPasswordUnknown: failure?.message
        case .failed: "Nothing was changed on the clip"
        default: nil
        }
    }
}
