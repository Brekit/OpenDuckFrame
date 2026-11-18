import Foundation

/// Explicit source-rate selection, not a claim about the game's actual render rate.
/// Timestamps remain on the device clock. The phase accumulator avoids 59.94→20 FPS
/// aliasing caused by comparing every frame to a rounded 1/30-second interval.
struct CaptureCardRateGate {
    private var next: Double?
    private var previous: Double?
    mutating func accepts(_ pts: Double, sourceFPS: Double?) -> Bool {
        guard pts.isFinite else { return false }
        defer { previous = pts }
        if let previous, pts <= previous || pts - previous > 0.5 { next = nil }
        guard let sourceFPS, sourceFPS > 0 else { return true }
        let interval = 1 / sourceFPS
        guard let deadline = next else { next = pts + interval; return true }
        guard pts + interval * 0.08 >= deadline else { return false }
        next = max(deadline + interval, pts + interval * 0.5)
        return true
    }
}

enum CaptureCardPolicy {
    /// Prefer a native uncompressed 60 Hz mode no larger than the selected display.
    /// 4K remains an explicit quality choice, never a claim about HDMI timing.
    static func score(width: Int, height: Int, fps: Double, compressed: Bool,
                      displayWidth: Int, displayHeight: Int) -> Double {
        let target = Double(max(1, displayWidth * displayHeight))
        let area = Double(max(1, width * height))
        return abs(log(area / target)) * 100 + abs(fps - 60) * 2 + (compressed ? 80 : 0)
    }
    static func sourceFPS(captureFPS: Double, thirtyFPS: Bool) -> Double? {
        guard thirtyFPS else { return nil }
        return captureFPS > 29 && captureFPS < 30 || captureFPS > 59 && captureFPS < 60
            ? 30_000 / 1_001 : 30
    }
}
