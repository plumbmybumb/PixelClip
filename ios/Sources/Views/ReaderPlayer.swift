import CoreGraphics
import Foundation
import Observation
import PixelClipKit

/// The phone-side RSVP preview: the clip's own timing (`RSVPTiming`) and painter (`ReaderPreview`,
/// the port of `rsvp_paint.c`) over the text's word index, drawn from the typeface's real atlases.
/// Play/pause, scrub, speed changes take effect on the next word.
@MainActor @Observable
final class ReaderPlayer {
    private(set) var words: [RSVPWord] = []
    private(set) var frame: ClipFrames?
    private(set) var isPlaying = false
    /// The word on screen (or the one the scrubber points at).
    var position = 0 {
        didSet {
            guard position != oldValue else { return }
            if !isPlaying { render() }
        }
    }
    var wpm = RSVPTiming.defaultWPM
    /// After the last word the card shows briefly, like the clip.
    private(set) var atEnd = false

    @ObservationIgnored private var font: ReaderBoundFont?
    @ObservationIgnored private var loop: Task<Void, Never>?

    var hasFont: Bool { font != nil }
    var count: Int { words.count }

    func load(words: [RSVPWord], position: Int) {
        self.words = words
        self.position = min(max(0, position), max(0, words.count - 1))
        render()
    }

    func setFont(_ f: ReaderFont?) {
        font = f.map(ReaderBoundFont.init)
        render()
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !words.isEmpty, font != nil, !isPlaying else { return }
        if atEnd || position >= words.count - 1 { position = 0 }
        atEnd = false
        isPlaying = true
        loop = Task { [weak self] in await self?.run() }
    }

    func pause() {
        isPlaying = false
        loop?.cancel()
        loop = nil
        atEnd = false
        render()
    }

    private func run() async {
        while isPlaying, !Task.isCancelled {
            guard position < words.count else { break }
            let w = words[position]
            show(w.text)
            try? await Task.sleep(for: .milliseconds(RSVPTiming.wordMs(w, wpm: wpm)))
            guard isPlaying, !Task.isCancelled else { return }
            if w.flags.contains(.paragraph) {
                show(nil)
                try? await Task.sleep(for: .milliseconds(RSVPTiming.paragraphBlankMs))
                guard isPlaying, !Task.isCancelled else { return }
            }
            if position + 1 >= words.count { break }
            position += 1
        }
        guard isPlaying, !Task.isCancelled, let font else { return }
        // The end card, as the clip shows it.
        atEnd = true
        let card = ReaderPreview.endCard(words: words.count, minutes: RSVPTiming.minutes(totalMs: RSVPTiming.totalMs(words, wpm: wpm)), font: font)
        frame = ClipFrames(single: ClipRenderer.makeCGImage(card))
        try? await Task.sleep(for: .milliseconds(RSVPTiming.endCardMs))
        guard isPlaying else { return }
        isPlaying = false
        atEnd = false
        position = 0
        render()
    }

    private func show(_ word: String?) {
        guard let font else { frame = nil; return }
        frame = ClipFrames(single: ClipRenderer.makeCGImage(ReaderPreview.frame(word: word, font: font, paused: false)))
    }

    /// The still for the current position (paused shows the clip's pause mark).
    func render() {
        guard let font else { frame = nil; return }
        let text = words.indices.contains(position) ? words[position].text : nil
        let f = ReaderPreview.frame(word: text, font: font, paused: !isPlaying && !words.isEmpty)
        frame = ClipFrames(single: ClipRenderer.makeCGImage(f))
    }
}
