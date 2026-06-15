import Testing

@testable import SummondCore

@Suite("Restart throttle")
struct RestartThrottleTests {
  @Test("Allows the tap on a first launch with no history")
  func allowsFirstLaunch() {
    let throttle = RestartThrottle(windowSeconds: 60, maxLaunchesInWindow: 5)
    let history = throttle.record([], now: 1_000)

    #expect(history == [1_000])
    #expect(throttle.launchCount(in: history, now: 1_000) == 1)
    #expect(throttle.shouldInstallTap(launches: history, now: 1_000))
  }

  @Test("Allows the tap while launches stay at or under the threshold")
  func allowsUpToThreshold() {
    let throttle = RestartThrottle(windowSeconds: 60, maxLaunchesInWindow: 5)
    // Four prior launches + this one == 5, which is exactly the limit.
    let history = throttle.record([1_010, 1_020, 1_030, 1_040], now: 1_050)

    #expect(throttle.launchCount(in: history, now: 1_050) == 5)
    #expect(throttle.shouldInstallTap(launches: history, now: 1_050))
  }

  @Test("Suppresses the tap once launches exceed the threshold in the window")
  func suppressesWhenLooping() {
    let throttle = RestartThrottle(windowSeconds: 60, maxLaunchesInWindow: 5)
    // Five prior launches + this one == 6, over the limit: crash loop.
    let history = throttle.record([1_000, 1_010, 1_020, 1_030, 1_040], now: 1_050)

    #expect(throttle.launchCount(in: history, now: 1_050) == 6)
    #expect(!throttle.shouldInstallTap(launches: history, now: 1_050))
  }

  @Test("Re-allows the tap once the burst ages out of the window")
  func selfHealsAfterWindow() {
    let throttle = RestartThrottle(windowSeconds: 60, maxLaunchesInWindow: 5)
    // A burst that trips the breaker at launch time.
    let history = throttle.record([1_000, 1_005, 1_010, 1_015, 1_020], now: 1_025)
    #expect(!throttle.shouldInstallTap(launches: history, now: 1_025))

    // Same fixed history, but evaluated well past the window: the burst has
    // aged out, so the agent recovers without a restart.
    #expect(throttle.shouldInstallTap(launches: history, now: 1_200))
  }

  @Test("Ages out launches older than the window so the agent self-heals")
  func prunesOldLaunches() {
    let throttle = RestartThrottle(windowSeconds: 60, maxLaunchesInWindow: 5)
    // Many launches, but all well outside the 60s window: only this one counts.
    let history = throttle.record([100, 200, 300, 400, 500, 600], now: 1_000)

    #expect(throttle.launchCount(in: history, now: 1_000) == 1)
    #expect(throttle.shouldInstallTap(launches: history, now: 1_000))
    #expect(history == [1_000])
  }

  @Test("Ignores future-dated timestamps from a backward clock change")
  func ignoresFutureTimestamps() {
    let throttle = RestartThrottle(windowSeconds: 60, maxLaunchesInWindow: 5)
    let history = throttle.record([5_000, 6_000, 7_000], now: 1_000)

    #expect(history == [1_000])
    #expect(throttle.launchCount(in: history, now: 1_000) == 1)
    #expect(throttle.shouldInstallTap(launches: history, now: 1_000))
  }

  @Test("Bounds the persisted history so it cannot grow without limit")
  func boundsHistory() {
    let throttle = RestartThrottle(windowSeconds: 10_000, maxLaunchesInWindow: 3)
    var history: [Double] = []
    var now = 0.0
    for _ in 0..<100 {
      now += 1
      history = throttle.record(history, now: now)
    }

    #expect(history.count <= max(3 * 4, 8))
  }
}
