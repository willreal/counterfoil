import Foundation
import AVFoundation
import SwiftUI

/// Loads a small, cached visual peak representation of each session's system-audio file.
/// The cache is deliberately tiny: 48 normalized peak values per file.
final class WaveformStore: ObservableObject {
    private struct CacheEntry: Codable {
        let modificationDate: TimeInterval
        let peaks: [Float]
    }

    @Published private(set) var peaksByKey: [String: [CGFloat]] = [:]

    private var cache: [String: CacheEntry] = [:]
    private var pending = Set<String>()
    private let cacheDefaultsKey = "Counterfoil.waveformCache.v1"
    private let peakCount = 48

    init() {
        guard let data = UserDefaults.standard.data(forKey: cacheDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return
        }
        cache = decoded
    }

    func request(for session: Session) {
        guard let url = audioURL(for: session),
              let modificationDate = modificationDate(for: url) else {
            return
        }

        let key = url.path
        if let entry = cache[key], abs(entry.modificationDate - modificationDate) < 0.5 {
            peaksByKey[key] = entry.peaks.map(CGFloat.init)
            return
        }
        guard !pending.contains(key) else { return }
        pending.insert(key)

        let count = peakCount
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let peaks = Self.computePeaks(at: url, count: count)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key)
                guard let peaks else { return }
                self.peaksByKey[key] = peaks.map(CGFloat.init)
                self.cache[key] = CacheEntry(modificationDate: modificationDate, peaks: peaks)
                self.saveCache()
            }
        }
    }

    func peaks(for session: Session) -> [CGFloat] {
        if let url = audioURL(for: session) {
            return peaksByKey[url.path] ?? Self.placeholder(for: session.id, count: peakCount)
        }
        return Self.placeholder(for: session.id, count: peakCount)
    }

    private func audioURL(for session: Session) -> URL? {
        let directory = URL(fileURLWithPath: session.dayDir, isDirectory: true)
        let m4a = directory.appendingPathComponent("\(session.stem).m4a")
        if FileManager.default.fileExists(atPath: m4a.path) { return m4a }

        let mp4 = directory.appendingPathComponent("\(session.stem).mp4")
        if FileManager.default.fileExists(atPath: mp4.path) { return mp4 }
        return nil
    }

    private func modificationDate(for url: URL) -> TimeInterval? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: cacheDefaultsKey)
    }

    private static func computePeaks(at url: URL, count: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }

        let totalFrames = max(Int64(1), file.length)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }

        var peaks = Array(repeating: Float(0), count: count)
        var framesRead: Int64 = 0

        while framesRead < totalFrames {
            let remaining = totalFrames - framesRead
            let frameCount = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            guard frameCount > 0, (try? file.read(into: buffer, frameCount: frameCount)) != nil else { break }

            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            if let channels = buffer.floatChannelData {
                for index in 0..<frames {
                    let value = abs(channels[0][index])
                    let bucket = min(count - 1, Int(Double(framesRead + Int64(index)) / Double(totalFrames) * Double(count)))
                    peaks[bucket] = max(peaks[bucket], value)
                }
            } else if let channels = buffer.int16ChannelData {
                for index in 0..<frames {
                    let value = abs(Float(channels[0][index])) / Float(Int16.max)
                    let bucket = min(count - 1, Int(Double(framesRead + Int64(index)) / Double(totalFrames) * Double(count)))
                    peaks[bucket] = max(peaks[bucket], value)
                }
            } else {
                return nil
            }
            framesRead += Int64(frames)
        }

        let maximum = max(peaks.max() ?? 0, 0.001)
        return peaks.map { min(1, max(0.08, $0 / maximum)) }
    }

    private static func placeholder(for id: String, count: Int) -> [CGFloat] {
        let seed = id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return (0..<count).map { index in
            let variation = CGFloat((seed + index * 17) % 9) / 100
            return 0.16 + variation
        }
    }
}
