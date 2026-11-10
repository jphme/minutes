import AVFoundation
import FluidAudio
import Foundation

/// Converts arbitrary audio files into the 16 kHz mono CAF format the recorder writes.
public enum AudioImport {
    public static func convert(_ source: URL, to destination: URL) throws {
        let samples = try AudioConverter().resampleAudioFile(source)
        let file = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_000 * 60
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: MonoResampler.targetFormat, frameCapacity: AVAudioFrameCount(n))
            else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            try file.write(from: buf)
            offset += n
        }
    }

    public static func duration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
