import AVFoundation

/// Streaming conversion of arbitrary PCM buffers to 16 kHz mono Float32, the format every model here expects.
/// Not thread-safe: use one instance per capture queue.
final class MonoResampler {
    static let targetRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let format = buffer.format
        // Mono float at 16 kHz: copy straight through.
        if format.sampleRate == Self.targetRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
            let data = buffer.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        // Downmix to mono ourselves first: AVAudioConverter's default channel mapping
        // drops the right channel instead of averaging.
        guard let mono = downmix(buffer) else { return [] }
        if mono.format.sampleRate == Self.targetRate {
            return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
        }
        if converter == nil || inputFormat != mono.format {
            converter = AVAudioConverter(from: mono.format, to: Self.targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = mono.format
        }
        guard let converter else { return [] }
        let ratio = Self.targetRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Averages all channels into a mono Float32 buffer at the input sample rate.
    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
            let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let dst = out.floatChannelData![0]
        if let src = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let p = src[0]
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += p[i * channels + c] }
                    dst[i] = sum / Float(channels)
                }
            } else {
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += src[c][i] }
                    dst[i] = sum / Float(channels)
                }
            }
        } else if let src = buffer.int16ChannelData {
            let scale: Float = 1.0 / 32768
            if buffer.format.isInterleaved {
                let p = src[0]
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(p[i * channels + c]) * scale }
                    dst[i] = sum / Float(channels)
                }
            } else {
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(src[c][i]) * scale }
                    dst[i] = sum / Float(channels)
                }
            }
        } else {
            return nil
        }
        return out
    }
}
