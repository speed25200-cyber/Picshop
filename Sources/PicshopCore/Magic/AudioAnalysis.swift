import Foundation

// Pure-Swift audio analysis behind the "magic" video tools: jump cuts that
// remove silences, cuts that land on the beat, captions that follow speech.
// Everything works on mono Float PCM so it runs (and is tested) anywhere; the
// video module only has to decode the soundtrack.

/// Mono PCM samples in -1…1.
public struct AudioSignal: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = max(1, sampleRate)
    }

    public var duration: Double { Double(samples.count) / sampleRate }

    /// Halves the sample rate with a two-tap average (a cheap anti-alias).
    public func downsampledByTwo() -> AudioSignal {
        guard samples.count > 1 else { return self }
        var out = [Float](repeating: 0, count: samples.count / 2)
        samples.withUnsafeBufferPointer { input in
            for index in 0..<out.count {
                out[index] = 0.5 * (input[2 * index] + input[2 * index + 1])
            }
        }
        return AudioSignal(samples: out, sampleRate: sampleRate / 2)
    }

    /// Brings any signal to ≤ `maximumRate` by repeated halving, which keeps
    /// the beat tracker's cost independent of the source format.
    public func reduced(toAtMost maximumRate: Double) -> AudioSignal {
        var signal = self
        while signal.sampleRate > maximumRate * 1.01, signal.samples.count > 1 {
            signal = signal.downsampledByTwo()
        }
        return signal
    }
}

// MARK: - Loudness

/// Short-term loudness (RMS in dBFS) sampled every `hop` seconds.
public struct LoudnessEnvelope: Sendable, Hashable {
    public var hop: Double
    public var decibels: [Float]

    public init(hop: Double, decibels: [Float]) {
        self.hop = hop
        self.decibels = decibels
    }

    public var duration: Double { Double(decibels.count) * hop }

    public func time(at index: Int) -> Double { Double(index) * hop }

    /// Value at a percentile (0…1) of the distribution.
    public func percentile(_ fraction: Double) -> Float {
        guard !decibels.isEmpty else { return -120 }
        let sorted = decibels.sorted()
        let index = Int((Double(sorted.count - 1) * fraction.clamped(to: 0...1)).rounded())
        return sorted[index]
    }

    /// RMS over sliding windows, reported in dBFS (floored at -120).
    public static func measure(_ signal: AudioSignal, hop: Double = 0.01, window: Double = 0.03) -> LoudnessEnvelope {
        let hopSamples = max(1, Int(signal.sampleRate * hop))
        let windowSamples = max(hopSamples, Int(signal.sampleRate * window))
        let count = signal.samples.count
        guard count > 0 else { return LoudnessEnvelope(hop: hop, decibels: []) }
        // Prefix sums of squares make every window O(1).
        var prefix = [Double](repeating: 0, count: count + 1)
        signal.samples.withUnsafeBufferPointer { samples in
            for index in 0..<count {
                let value = Double(samples[index])
                prefix[index + 1] = prefix[index] + value * value
            }
        }
        let frames = max(1, Int((Double(count) / Double(hopSamples)).rounded(.up)))
        var decibels = [Float](repeating: -120, count: frames)
        for frame in 0..<frames {
            let center = frame * hopSamples + hopSamples / 2
            let start = max(0, center - windowSamples / 2)
            let end = min(count, start + windowSamples)
            guard end > start else { continue }
            let meanSquare = (prefix[end] - prefix[start]) / Double(end - start)
            let rms = meanSquare.squareRoot()
            decibels[frame] = Float(max(-120, 20 * log10(max(rms, 1e-7))))
        }
        return LoudnessEnvelope(hop: hop, decibels: decibels)
    }
}

// MARK: - Silence detection (jump cuts)

/// Finds the pauses in speech so they can be cut out ("enlève les blancs").
///
/// The threshold adapts to each recording: it sits between the noise floor
/// (a low percentile) and the speech level (a high percentile), so a quiet
/// interview and a loud vlog are cut the same way. Every cut keeps a little
/// breath on both sides, which is what makes automatic jump cuts sound edited
/// rather than chopped.
public struct SilenceDetector: Sendable {
    /// Shortest pause worth removing, before padding.
    public var minimumSilence: Double
    /// Room kept around speech on each side of a cut.
    public var padding: Double
    /// Where the threshold sits between floor (0) and speech level (1).
    public var sensitivity: Double

    public init(minimumSilence: Double = 0.5, padding: Double = 0.12, sensitivity: Double = 0.3) {
        self.minimumSilence = minimumSilence
        self.padding = padding
        self.sensitivity = sensitivity.clamped(to: 0.05...0.9)
    }

    /// Threshold in dBFS for an envelope, or nil when there is no contrast
    /// between speech and background (music, constant noise).
    public func threshold(for envelope: LoudnessEnvelope) -> Float? {
        let floor = envelope.percentile(0.1)
        let speech = envelope.percentile(0.95)
        guard speech > -60 else { return nil }            // the whole file is silent
        guard speech - floor >= 9 else { return nil }      // no pauses to find
        return floor + Float(sensitivity) * (speech - floor)
    }

    /// Timeline ranges to remove, in seconds, sorted and non-overlapping.
    public func silentRanges(in envelope: LoudnessEnvelope) -> [TimeSpan] {
        guard let threshold = threshold(for: envelope), !envelope.decibels.isEmpty else { return [] }
        let count = envelope.decibels.count
        // A three-frame median removes clicks and single-frame dropouts.
        var quiet = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let a = envelope.decibels[max(0, index - 1)]
            let b = envelope.decibels[index]
            let c = envelope.decibels[min(count - 1, index + 1)]
            let median = max(min(a, b), min(max(a, b), c))
            quiet[index] = median < threshold
        }
        var ranges: [TimeSpan] = []
        var runStart: Int?
        for index in 0...count {
            let isQuiet = index < count && quiet[index]
            if isQuiet, runStart == nil { runStart = index }
            if !isQuiet, let start = runStart {
                runStart = nil
                let startTime = envelope.time(at: start)
                let endTime = envelope.time(at: index)
                // No padding against the file edges: there is no speech to protect there.
                let leading = start == 0 ? 0 : padding
                let trailing = index >= count ? 0 : padding
                let span = TimeSpan(start: startTime + leading, end: endTime - trailing)
                if span.duration >= minimumSilence { ranges.append(span) }
            }
        }
        return ranges
    }

    public func silentRanges(in signal: AudioSignal) -> [TimeSpan] {
        silentRanges(in: LoudnessEnvelope.measure(signal))
    }
}

// MARK: - FFT

/// Minimal iterative radix-2 FFT used by the onset detector.
public struct FFT: Sendable {
    public let size: Int
    private let cosines: [Float]
    private let sines: [Float]
    private let reversed: [Int]

    public init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        var cosines = [Float](repeating: 0, count: size / 2)
        var sines = [Float](repeating: 0, count: size / 2)
        for index in 0..<size / 2 {
            let angle = -2 * Double.pi * Double(index) / Double(size)
            cosines[index] = Float(cos(angle))
            sines[index] = Float(sin(angle))
        }
        self.cosines = cosines
        self.sines = sines
        let bits = Int(log2(Double(size)))
        var reversed = [Int](repeating: 0, count: size)
        for index in 0..<size {
            var value = index
            var result = 0
            for _ in 0..<bits {
                result = (result << 1) | (value & 1)
                value >>= 1
            }
            reversed[index] = result
        }
        self.reversed = reversed
    }

    /// Magnitudes of the first `size / 2 + 1` bins of a real frame.
    public func magnitudes(of frame: [Float]) -> [Float] {
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        for index in 0..<min(size, frame.count) { real[reversed[index]] = frame[index] }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosines[k * step]
                    let wi = sines[k * step]
                    let a = start + k
                    let b = a + half
                    let tr = wr * real[b] - wi * imaginary[b]
                    let ti = wr * imaginary[b] + wi * real[b]
                    real[b] = real[a] - tr
                    imaginary[b] = imaginary[a] - ti
                    real[a] += tr
                    imaginary[a] += ti
                }
                start += length
            }
            length <<= 1
        }
        var result = [Float](repeating: 0, count: size / 2 + 1)
        for index in 0..<result.count {
            result[index] = (real[index] * real[index] + imaginary[index] * imaginary[index]).squareRoot()
        }
        return result
    }
}

// MARK: - Beat tracking

/// Tempo and beat positions of a piece of music.
public struct BeatGrid: Hashable, Codable, Sendable {
    public var bpm: Double
    /// Beat times in seconds, ascending.
    public var beats: [Double]
    /// Index into `beats` of the first downbeat (bar start, 4/4 assumed).
    public var downbeatOffset: Int

    public init(bpm: Double, beats: [Double], downbeatOffset: Int = 0) {
        self.bpm = bpm
        self.beats = beats
        self.downbeatOffset = downbeatOffset
    }

    public var period: Double { 60 / max(1, bpm) }

    /// Bar starts (every fourth beat from the downbeat).
    public var downbeats: [Double] {
        stride(from: downbeatOffset, to: beats.count, by: 4).map { beats[$0] }
    }

    /// The beat nearest to `time`.
    public func nearestBeat(to time: Double) -> Double? {
        beats.min { abs($0 - time) < abs($1 - time) }
    }

    /// A regular grid, for when no music is present.
    public static func metronome(bpm: Double, duration: Double, start: Double = 0) -> BeatGrid {
        let period = 60 / max(1, bpm)
        var beats: [Double] = []
        var time = start
        while time <= duration + 1e-9 {
            beats.append(time)
            time += period
        }
        return BeatGrid(bpm: bpm, beats: beats)
    }
}

/// Onset-strength beat tracker: spectral flux → tempo by autocorrelation with
/// a perceptual prior → beats by dynamic programming (Ellis, 2007).
public struct BeatTracker: Sendable {
    public var minimumBPM: Double = 60
    public var maximumBPM: Double = 190
    /// Preferred tempo of the prior (listeners tap near 120 BPM).
    public var preferredBPM: Double = 120
    /// How strongly beats keep a regular spacing.
    public var tightness: Double = 100

    public init() {}

    /// Spectral-flux onset envelope and its frame rate.
    public func onsetEnvelope(_ signal: AudioSignal) -> (envelope: [Float], frameRate: Double) {
        let reduced = signal.reduced(toAtMost: 11_025)
        let frameSize = reduced.sampleRate > 8_000 ? 1024 : 512
        let hop = frameSize / 4
        let fft = FFT(size: frameSize)
        var window = [Float](repeating: 0, count: frameSize)
        for index in 0..<frameSize {
            window[index] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frameSize)))
        }
        let samples = reduced.samples
        guard samples.count >= frameSize else { return ([], reduced.sampleRate / Double(hop)) }
        let frames = (samples.count - frameSize) / hop + 1
        var envelope = [Float](repeating: 0, count: frames)
        var previous = [Float](repeating: 0, count: frameSize / 2 + 1)
        var frame = [Float](repeating: 0, count: frameSize)
        for index in 0..<frames {
            let offset = index * hop
            for k in 0..<frameSize { frame[k] = samples[offset + k] * window[k] }
            let spectrum = fft.magnitudes(of: frame)
            var flux: Float = 0
            for bin in 1..<spectrum.count {
                let value = log(1 + 100 * spectrum[bin])
                let rise = value - previous[bin]
                if rise > 0 { flux += rise }
                previous[bin] = value
            }
            envelope[index] = flux
        }
        // Remove the slowly varying part and keep the rises.
        let frameRate = reduced.sampleRate / Double(hop)
        let smoothing = max(1, Int(frameRate * 0.25))
        var prefix = [Float](repeating: 0, count: frames + 1)
        for index in 0..<frames { prefix[index + 1] = prefix[index] + envelope[index] }
        var detrended = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            let start = max(0, index - smoothing)
            let end = min(frames, index + smoothing + 1)
            let mean = (prefix[end] - prefix[start]) / Float(end - start)
            detrended[index] = max(0, envelope[index] - mean)
        }
        // Normalise to unit standard deviation so `tightness` means the same thing for every song.
        let mean = detrended.reduce(0, +) / Float(max(1, frames))
        let variance = detrended.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, frames))
        let deviation = max(variance.squareRoot(), 1e-6)
        return (detrended.map { $0 / deviation }, frameRate)
    }

    /// Tempo in BPM from the onset envelope's autocorrelation, weighted by a
    /// log-Gaussian prior around `preferredBPM`.
    public func estimateTempo(envelope: [Float], frameRate: Double) -> Double? {
        let minimumLag = max(1, Int((60 / maximumBPM * frameRate).rounded(.down)))
        let maximumLag = Int((60 / minimumBPM * frameRate).rounded(.up))
        guard envelope.count > maximumLag * 2 else { return nil }
        var scores = [Double](repeating: 0, count: maximumLag + 2)
        let count = envelope.count
        envelope.withUnsafeBufferPointer { values in
            for lag in minimumLag...maximumLag + 1 {
                var sum: Double = 0
                for index in lag..<count { sum += Double(values[index] * values[index - lag]) }
                let bpm = 60 * frameRate / Double(lag)
                let octaves = log2(bpm / preferredBPM)
                let prior = exp(-0.5 * (octaves / 0.9) * (octaves / 0.9))
                scores[lag] = sum / Double(count - lag) * prior
            }
        }
        guard let best = (minimumLag...maximumLag).max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        // Parabolic interpolation for a sub-frame lag.
        var lag = Double(best)
        if best > minimumLag, best < maximumLag {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 { lag += 0.5 * (a - c) / denominator }
        }
        return 60 * frameRate / lag
    }

    /// Beat frames by dynamic programming over the onset envelope.
    public func trackBeats(envelope: [Float], frameRate: Double, bpm: Double) -> [Int] {
        let period = 60 * frameRate / bpm
        let count = envelope.count
        guard count > Int(period * 2) else { return [] }
        var score = [Double](repeating: 0, count: count)
        var backlink = [Int](repeating: -1, count: count)
        let lowest = Int((period / 2).rounded(.down))
        let highest = Int((period * 2).rounded(.up))
        for t in 0..<count {
            var best = -Double.infinity
            var bestIndex = -1
            if t - lowest >= 0 {
                for previous in max(0, t - highest)...(t - lowest) {
                    let ratio = Double(t - previous) / period
                    let penalty = tightness * pow(log(ratio), 2)
                    let candidate = score[previous] - penalty
                    if candidate > best {
                        best = candidate
                        bestIndex = previous
                    }
                }
            }
            let local = Double(envelope[t])
            if bestIndex >= 0, best > 0 {
                score[t] = local + best
                backlink[t] = bestIndex
            } else {
                score[t] = local
            }
        }
        // Start from the best score in the last period, then follow the links back.
        let tailStart = max(0, count - Int(period.rounded(.up)))
        var cursor = (tailStart..<count).max { score[$0] < score[$1] } ?? count - 1
        var beats: [Int] = []
        while cursor >= 0 {
            beats.append(cursor)
            cursor = backlink[cursor]
        }
        return beats.reversed()
    }

    /// Full analysis of a piece of music.
    public func analyze(_ signal: AudioSignal) -> BeatGrid? {
        let (envelope, frameRate) = onsetEnvelope(signal)
        guard let bpm = estimateTempo(envelope: envelope, frameRate: frameRate) else { return nil }
        let frames = trackBeats(envelope: envelope, frameRate: frameRate, bpm: bpm)
        guard frames.count >= 2 else { return nil }
        // Frame index → the centre of its analysis window.
        let latency = 2.0 / frameRate
        let beats = frames.map { Double($0) / frameRate + latency }
        // Downbeat: the phase (0…3) whose beats carry the most onset energy.
        var phaseEnergy = [Double](repeating: 0, count: 4)
        for (index, frame) in frames.enumerated() { phaseEnergy[index % 4] += Double(envelope[frame]) }
        let downbeat = (0..<4).max { phaseEnergy[$0] < phaseEnergy[$1] } ?? 0
        return BeatGrid(bpm: bpm, beats: beats, downbeatOffset: downbeat)
    }
}
