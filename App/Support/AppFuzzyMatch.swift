import Foundation

enum AppFuzzyMatch {
  static func score(_ query: String, _ text: String) -> Int? {
    if query.isEmpty {
      return 0
    }

    let queryCharacters = Array(query.lowercased())
    let textCharacters = Array(text.lowercased())
    var queryIndex = 0
    var score = 0
    var run = 0
    var previousMatchIndex = -2
    var previousCharacter: Character = " "

    for (index, character) in textCharacters.enumerated() {
      guard queryIndex < queryCharacters.count, character == queryCharacters[queryIndex] else {
        previousCharacter = character
        continue
      }

      var bonus = 1
      if index == previousMatchIndex + 1 {
        run += 1
        bonus += run * 2
      } else {
        run = 0
      }
      if index == 0 || previousCharacter == " " || previousCharacter == "." {
        bonus += 6
      }
      if index == queryIndex {
        bonus += 2
      }

      score += bonus
      previousMatchIndex = index
      queryIndex += 1
      previousCharacter = character
    }

    return queryIndex == queryCharacters.count ? score : nil
  }

  static func rank(_ apps: [AppDisplayInfo], _ query: String) -> [AppDisplayInfo] {
    guard !query.isEmpty else {
      return apps
    }

    return apps.compactMap { app -> (AppDisplayInfo, Int)? in
      let nameScore = score(query, app.displayName)
      let bundleScore = score(query, app.bundleID).map { $0 / 3 }
      guard let bestScore = [nameScore, bundleScore].compactMap({ $0 }).max() else {
        return nil
      }
      return (app, bestScore)
    }
    .sorted { lhs, rhs in
      if lhs.1 != rhs.1 {
        return lhs.1 > rhs.1
      }
      return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName)
        == .orderedAscending
    }
    .map(\.0)
  }
}
