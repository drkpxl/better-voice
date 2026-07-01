import Foundation

/// Result of a phase-locked mix pass over a pair of independently-clocked sample streams.
public struct MixResult: Sendable, Equatable {
    /// (mic+sys)*0.5 over the aligned prefix (min of the two lengths).
    public let mixed: [Float]
    /// Carried mic samples (at most one of the two remainders is non-empty).
    public let micRemainder: [Float]
    /// Carried sys samples.
    public let sysRemainder: [Float]
    /// Oldest samples dropped from the longer remainder to bound clock drift.
    public let droppedForDrift: Int

    public init(mixed: [Float], micRemainder: [Float], sysRemainder: [Float], droppedForDrift: Int) {
        self.mixed = mixed
        self.micRemainder = micRemainder
        self.sysRemainder = sysRemainder
        self.droppedForDrift = droppedForDrift
    }
}

/// Phase-locked mix: sums the aligned prefix (min(mic,sys) samples), carries the leftover from the
/// longer stream to be aligned against the other stream's future samples instead of against zeros.
/// To bound unbounded accumulation under sustained clock drift, if the carried remainder exceeds
/// `maxCarry`, its OLDEST excess samples are dropped (a small resync glitch beats growing latency).
public func alignAndMix(mic: [Float], sys: [Float], maxCarry: Int) -> MixResult {
    let n = min(mic.count, sys.count)

    var mixed = [Float](repeating: 0, count: n)
    for i in 0..<n {
        mixed[i] = (mic[i] + sys[i]) * 0.5
    }

    var micRem = n < mic.count ? Array(mic[n...]) : []
    var sysRem = n < sys.count ? Array(sys[n...]) : []

    // Drift cap: at most one remainder is non-empty. Drop the OLDEST excess so the
    // carried stream stays current (keeps latency bounded at the cost of a tiny glitch).
    var dropped = 0
    if micRem.count > maxCarry {
        dropped = micRem.count - maxCarry
        micRem = Array(micRem[dropped...])
    } else if sysRem.count > maxCarry {
        dropped = sysRem.count - maxCarry
        sysRem = Array(sysRem[dropped...])
    }

    return MixResult(mixed: mixed, micRemainder: micRem, sysRemainder: sysRem, droppedForDrift: dropped)
}
