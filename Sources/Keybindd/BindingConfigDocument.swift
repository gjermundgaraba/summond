import Foundation
import TOML

struct BindingConfigLoadResult: Sendable {
  let bindings: [AppBinding]
  let snapshot: BindingSnapshot
}

enum BindingConfigDocument {
  static func parse(_ data: Data) throws -> [AppBinding] {
    try parseRecords(data).enumerated().map { offset, record in
      do {
        return try binding(from: record)
      } catch let error as BindingValidationError {
        throw BindingConfigError.invalidBinding(index: offset + 1, error: error)
      }
    }
  }

  static func serialize(_ bindings: [AppBinding]) -> String {
    let encoder = TOMLEncoder()
    let document = BindingDocument(bindings: bindings.map(BindingDocumentRecord.init(binding:)))
    let data: Data

    do {
      data = try encoder.encode(document)
    } catch {
      preconditionFailure("Unexpected config serialization error: \(error.localizedDescription)")
    }

    let text = String(decoding: data, as: UTF8.self)
    return text.hasSuffix("\n") ? text : text + "\n"
  }

  private static func parseRecords(_ data: Data) throws -> [BindingDocumentRecord] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw BindingConfigError.invalidDocument("Config file is not valid UTF-8")
    }

    do {
      return try TOMLDecoder().decode(BindingDocument.self, from: text).bindings
    } catch {
      throw BindingConfigError.invalidDocument(error.localizedDescription)
    }
  }

  private static func binding(from record: BindingDocumentRecord) throws -> AppBinding {
    let shortcut = Shortcut(key: record.key, mods: record.mods)
    let app = try AppTarget(
      bundleID: record.app.bundleID, mode: AppOpenMode(parsing: record.app.mode))
    return AppBinding(shortcut: shortcut, app: app)
  }
}

private struct BindingDocumentApp: Codable, Sendable, Equatable {
  let bundleID: String
  let mode: String

  enum CodingKeys: String, CodingKey {
    case mode
    case bundleID = "bundle_id"
  }
}

private struct BindingDocumentRecord: Codable, Sendable, Equatable {
  let key: String
  let mods: [String]
  let app: BindingDocumentApp

  init(key: String, mods: [String], app: BindingDocumentApp) {
    self.key = key
    self.mods = mods
    self.app = app
  }

  init(binding: AppBinding) {
    self.init(
      key: binding.shortcut.key,
      mods: binding.shortcut.mods,
      app: BindingDocumentApp(bundleID: binding.app.bundleID, mode: binding.app.mode.rawValue)
    )
  }
}

private struct BindingDocument: Codable, Sendable {
  let bindings: [BindingDocumentRecord]
}
