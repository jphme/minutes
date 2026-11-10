import Foundation

/// Measures the real sample rate of a HAL stream from frames delivered versus host-clock time.
///
/// The format a device or tap reports can be stale: when a Bluetooth headset switches to call mode, or another
/// process (Siri, a call app) changes the device rate, buffers keep arriving at the new rate while the cached
/// format still says 48 kHz. Interpreting 16 kHz audio as 48 kHz plays it three times too fast, and speech
/// recognition returns nothing useful. Checking the delivered rate against the clock catches every such case.
struct RateTracker {
    static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    private(set) var rate: Double
    private var anchorHost: UInt64?
    private var framesSinceAnchor = 0
    private var lastCheckFrames = 0
    private var lastHost: UInt64 = 0
    private var lastFrames = 0

    init(rate: Double) {
        self.rate = rate
    }

    /// Call once per buffer, before converting it. Returns the sample rate to use for this buffer.
    mutating func update(frames: Int, hostTime: UInt64) -> Double {
        // A pause in delivery (device sleep, route change) is not a rate change: start measuring again.
        if lastHost > 0 {
            let gap = HostTime.seconds(hostTime &- lastHost)
            if gap > max(0.25, 4 * Double(lastFrames) / rate) || hostTime < lastHost { reset() }
        }
        lastHost = hostTime
        lastFrames = frames
        guard let anchor = anchorHost else {
            anchorHost = hostTime
            framesSinceAnchor = frames
            return rate
        }
        // `hostTime` is the time of this buffer's first frame, so every frame counted so far was delivered before it.
        let elapsed = HostTime.seconds(hostTime &- anchor)
        if elapsed >= 2, framesSinceAnchor - lastCheckFrames >= Int(rate) {
            lastCheckFrames = framesSinceAnchor
            let measured = Double(framesSinceAnchor) / elapsed
            if abs(measured - rate) / rate > 0.04,
                let nearest = Self.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }),
                abs(nearest - measured) / nearest < 0.04
            {
                rate = nearest
                reset()
            } else if elapsed > 30 {
                // Re-anchor periodically so a later rate change is noticed quickly.
                reset()
            }
        }
        framesSinceAnchor += frames
        return rate
    }

    mutating func reset() {
        anchorHost = nil
        framesSinceAnchor = 0
        lastCheckFrames = 0
    }
}
