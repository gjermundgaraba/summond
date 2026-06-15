import Foundation
import SummondCore

struct AppDisplayInfo: Identifiable, Equatable {
  var id: String { bundleID }
  var bundleID: String
  var displayName: String
  var url: URL?
  var isInstalled: Bool

  static func missing(bundleID: String) -> AppDisplayInfo {
    AppDisplayInfo(
      bundleID: bundleID,
      displayName: bundleID,
      url: nil,
      isInstalled: false
    )
  }

  static func installed(
    bundleID: String,
    displayName: String,
    url: URL
  ) -> AppDisplayInfo {
    AppDisplayInfo(
      bundleID: bundleID,
      displayName: displayName,
      url: url,
      isInstalled: true
    )
  }
}

struct BindingEditorDraft: Identifiable, Equatable {
  enum Purpose: Equatable {
    case add
    case edit(UUID)
  }

  var purpose: Purpose
  var shortcut: ShortcutDraft
  var bundleID: String
  var mode: AppOpenMode

  var id: String {
    switch purpose {
    case .add:
      "add"
    case .edit(let id):
      "edit-\(id.uuidString)"
    }
  }

  var editingID: UUID? {
    if case .edit(let id) = purpose {
      return id
    }
    return nil
  }
}

struct ShortcutDraft: Equatable {
  var key: String
  var mods: [String]

  static let empty = ShortcutDraft(key: "", mods: [])

  var isEmpty: Bool {
    key.isEmpty && mods.isEmpty
  }

  var shortcut: Shortcut? {
    guard !key.isEmpty else {
      return nil
    }
    return Shortcut(key: key, mods: mods)
  }
}

struct PreferencesBanner: Identifiable, Equatable {
  enum Tone: Equatable {
    case info
    case warning
    case error
  }

  var id = UUID()
  var tone: Tone
  var title: String
  var message: String
}
