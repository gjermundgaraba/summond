import Foundation

/// Persists agent launch timestamps across process restarts so `RestartThrottle`
/// can detect a crash loop. Backed by the agent's own `UserDefaults` domain
/// (`net.garaba.summond.agent`); this is private operational state, kept out of
/// the shared configuration suite the preferences app reads.
struct LaunchHistoryStore {
  private let defaults: UserDefaults
  private let key = "agent.launchHistory.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> [Double] {
    defaults.array(forKey: key) as? [Double] ?? []
  }

  func save(_ history: [Double]) {
    defaults.set(history, forKey: key)
    // Force persistence now: this state exists to survive a rapid crash loop, so
    // it must reach disk before the agent can die and relaunch.
    defaults.synchronize()
  }
}
