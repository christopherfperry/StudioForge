import Foundation
import SFCore

/// Helpers for the "Show Playing Notes" display: which notes a track is sounding at a time.
extension Project {
    /// MIDI pitches sounding on a track at `seconds` (unmuted MIDI clips only; notes are clipped
    /// to their clip's length, matching what the engine plays).
    public func soundingMIDIPitches(track: Track, at seconds: Double) -> [Int] {
        let beat = beats(forSeconds: seconds)
        var out: [Int] = []
        for clip in track.midiClips where !clip.muted {
            let local = beat - clip.startBeat
            guard local >= 0, local < clip.lengthBeats else { continue }
            for n in clip.notes where n.velocity > 0 {
                let end = min(n.startBeat + max(n.durationBeats, 0.05), clip.lengthBeats)
                if local >= n.startBeat && local < end { out.append(n.pitch) }
            }
        }
        return out
    }

    /// The unmuted audio clip under `seconds` on a track and the matching time inside its file.
    public func audioClipPosition(track: Track, at seconds: Double) -> (clip: AudioClip, fileTime: Double)? {
        // Later clips draw/play on top, so search from the end.
        for clip in track.audioClips.reversed() where !clip.muted && !clip.isWetCapture {
            if seconds >= clip.start && seconds < clip.end { return (clip, clip.offset + seconds - clip.start) }
        }
        return nil
    }
}
