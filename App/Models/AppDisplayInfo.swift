import Foundation
import SummondCore

struct AppDisplayInfo: Identifiable, Equatable {
  var id: String { bundleID }
  var bundleID: String
  var displayName: String
  var url: URL?
  var isInstalled: Bool { url != nil }

  static func missing(bundleID: String) -> AppDisplayInfo {
    AppDisplayInfo(
      bundleID: bundleID,
      displayName: bundleID,
      url: nil
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
      url: url
    )
  }
}

struct ShortcutEditorDraft: Identifiable, Equatable {
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

struct ShortcutSummary: Equatable {
  var shortcut: Shortcut
  var applicationName: String
}

enum ShortcutDraftIssue: Equatable {
  case missingShortcut
  case unsupportedKey(String)
  case unsupportedModifiers([String])
  case unsafePrintableShortcut
  case missingApplication
  case duplicate(existing: ShortcutSummary)

  var message: String {
    switch self {
    case .missingShortcut:
      "Record a shortcut."
    case .unsupportedKey:
      "That key is not supported by Summond yet."
    case .unsupportedModifiers(let modifiers):
      "Unsupported modifier: \(modifiers.joined(separator: ", "))."
    case .unsafePrintableShortcut:
      "Printable shortcuts must include Command, Option, or Control."
    case .missingApplication:
      "Choose an application."
    case .duplicate(let existing):
      "\(ShortcutFormatter.symbols(for: existing.shortcut)) already opens \(existing.applicationName)."
    }
  }
}

enum ShortcutRecordResult: Equatable {
  case recorded(ShortcutDraft)
  case unsupportedKey

  var message: String? {
    switch self {
    case .recorded:
      nil
    case .unsupportedKey:
      "That key is not supported by Summond yet."
    }
  }
}

enum SaveShortcutResult: Equatable {
  case saved
  case savedButReloadFailed(String)
  case failed(String)
  case invalid([ShortcutDraftIssue])
}

enum ConfigurationUpdateResult: Equatable {
  case saved
  case savedButReloadFailed(String)
  case failed(String)
}
