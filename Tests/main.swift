// Metrics tests. Run with: Tests/run.sh
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok    \(msg)" : "  FAIL  \(msg)")
    if !cond { failures += 1 }
}

print("Sampler: back-to-back samples (what happens at app launch)")
do {
    let s = Sampler()
    s.sample()                       // prime
    check(s.samplesTaken == 1, "first call takes a sample")
    s.sample()                       // immediately again: a few ms of ticks is noise
    Thread.sleep(forTimeInterval: 0.05)
    s.sample()
    check(s.samplesTaken == 1, "calls within \(Sampler.minInterval)s of the last sample are ignored")
    check(s.cpu.total == 0, "no CPU value from a near-zero window (got \(Fmt.pct(s.cpu.total)))")
    Thread.sleep(forTimeInterval: Sampler.minInterval + 0.05)
    s.sample()
    check(s.samplesTaken == 2, "a call after the minimum interval samples again")
}

print("Sampler: one-second window")
do {
    let s = Sampler()
    s.sample()
    Thread.sleep(forTimeInterval: 1)
    s.sample()
    check((0...1).contains(s.cpu.total), "CPU total in 0...100% (\(Fmt.pct(s.cpu.total)))")
    check(s.cpu.user >= 0 && s.cpu.system >= 0, "CPU user/system non-negative")
    check(s.memory.total == ProcessInfo.processInfo.physicalMemory, "memory total equals physical memory")
    check(s.memory.used > 0 && s.memory.fraction > 0 && s.memory.fraction <= 1, "memory used fraction in (0, 1] (\(Fmt.pct(s.memory.fraction)))")
    check(s.memory.activeFraction > 0 && s.memory.activeFraction <= 1, "active-memory fraction in (0, 1]")
    check(s.net.downBytesPerSec >= 0 && s.net.upBytesPerSec >= 0, "network rates non-negative")
}

print("Network deltas")
do {
    typealias C = NetMath.Counters
    let prev = ["en0": C(down: 1_000, up: 500)]
    check(NetMath.delta(from: prev, to: ["en0": C(down: 1_600, up: 700)]) == C(down: 600, up: 200), "counts bytes moved on an interface")
    check(NetMath.delta(from: prev, to: ["en0": C(down: 1_600, up: 700), "en5": C(down: 9_000_000_000, up: 1)]) == C(down: 600, up: 200),
          "an interface that just came up doesn't add its since-boot total (no spike)")
    check(NetMath.delta(from: ["en0": C(down: 1_000, up: 500), "en5": C(down: 9_000, up: 9_000)], to: ["en0": C(down: 1_600, up: 700)]) == C(down: 600, up: 200),
          "an interface that went away doesn't cancel traffic on the others")
    check(NetMath.delta(from: prev, to: ["en0": C(down: 10, up: 600)]) == C(down: 0, up: 100), "a counter that went backwards (reset) adds nothing")
    check(NetMath.delta(from: [:], to: prev) == C(down: 0, up: 0), "no previous snapshot means no traffic")
}

print("Formatting")
check(Fmt.compactRate(0, bits: true) == "0", "0 B/s -> \"0\"")
check(Fmt.compactRate(1_012_500, bits: true) == "8.1M", "1.0125 MB/s in bits -> \"8.1M\"")
check(Fmt.compactRate(10_125_000, bits: true) == "81M", "10.125 MB/s in bits -> \"81M\"")
check(Fmt.compactRate(512_000, bits: false) == "512K", "512 KB/s in bytes -> \"512K\"")
check(Fmt.compactRate(2_000_000_000, bits: false) == "2.0G", "2 GB/s -> \"2.0G\"")
check(Fmt.compactRate(999_000, bits: false) == "999K", "999 KB/s stays 4 chars")
// Up to 100 TB/s (800 Tb/s), far beyond any real link, the menu bar text must fit its 4-character column.
check((0..<146).allSatisfy { Fmt.compactRate(pow(1.25, Double($0)), bits: true).count <= 4 }, "compact rates fit 4 characters up to 100 TB/s")
check(stride(from: 0.0, to: 2_000_000, by: 7.3).allSatisfy { Fmt.compactRate($0, bits: false).count <= 4 }, "compact rates fit 4 characters across 0–2 MB/s")
check(Fmt.pct(0.674) == "67%" && Fmt.pct(1) == "100%" && Fmt.pct(0) == "0%", "percent formatting")
check(Fmt.rate(0, bits: true) == "0 Kb/s", "zero rate label")
check(Fmt.bytes(0) == "0 KB" || Fmt.bytes(0) == "0 bytes", "zero bytes is numeric, not \"Zero KB\" (\(Fmt.bytes(0)))")

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
