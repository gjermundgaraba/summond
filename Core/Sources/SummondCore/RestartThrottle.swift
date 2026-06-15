/// Crash-loop circuit breaker for the agent.
///
/// The LaunchAgent runs under `KeepAlive { SuccessfulExit = false }`, so launchd
/// relaunches the agent after every unsuccessful exit. If the agent keeps
/// crashing (for example, a code-signature fault on a locally-signed build), it
/// re-installs an active global `CGEvent` tap on each launch; while that loop
/// runs the window server stalls every keystroke on a tap whose owner keeps
/// dying, which renders the keyboard nearly unusable.
///
/// The agent records each launch (`record`) and then asks, live, whether
/// installing the tap is currently safe (`shouldInstallTap`). Because the launch
/// timestamps are fixed but the evaluation clock keeps advancing, a burst that
/// trips the breaker ages out of the window on its own: re-checking a little
/// later returns `true` again, so the agent self-heals without an external
/// restart. A non-functional tap for one cooldown window is strictly better than
/// a frozen keyboard.
public struct RestartThrottle: Sendable {
  public let windowSeconds: Double
  public let maxLaunchesInWindow: Int

  public init(windowSeconds: Double = 60, maxLaunchesInWindow: Int = 5) {
    self.windowSeconds = windowSeconds
    self.maxLaunchesInWindow = maxLaunchesInWindow
  }

  /// Records `now` as a launch and returns the pruned, bounded history to
  /// persist for the next launch. `previousLaunches` are epoch-second
  /// timestamps; any in the future (e.g. after a backward clock change) are
  /// dropped so they can't suppress the tap forever.
  public func record(_ previousLaunches: [Double], now: Double) -> [Double] {
    var recent = launchesInWindow(previousLaunches, now: now)
    recent.append(now)
    recent.sort()
    // Bound the persisted history so the store can't grow without limit.
    return Array(recent.suffix(max(maxLaunchesInWindow * 4, 8)))
  }

  /// Number of launches inside the trailing window ending at `now`.
  public func launchCount(in launches: [Double], now: Double) -> Int {
    launchesInWindow(launches, now: now).count
  }

  /// Whether installing the global event tap is currently safe. Evaluated live
  /// against a fixed launch history and an advancing `now`, so a tripped breaker
  /// recovers once the burst falls out of the window.
  public func shouldInstallTap(launches: [Double], now: Double) -> Bool {
    launchCount(in: launches, now: now) <= maxLaunchesInWindow
  }

  private func launchesInWindow(_ launches: [Double], now: Double) -> [Double] {
    let cutoff = now - windowSeconds
    return launches.filter { $0 > cutoff && $0 <= now }
  }
}
