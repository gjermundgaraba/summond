import AppKit
import ApplicationServices
import Foundation
import OSLog

struct DockMenuOpener: Sendable {
  private let logger: Logger

  init(logger: Logger = KeybinddLoggers.opener) {
    self.logger = logger
  }

  @MainActor
  func openNewWindow(for identity: AppIdentity) async -> Bool {
    guard let dockElements = resolveDockElements(for: identity) else {
      return false
    }

    guard revealMenu(for: identity, appElement: dockElements.app) else {
      return false
    }

    guard
      let menu = await findVisibleMenu(
        appElement: dockElements.app, dockElement: dockElements.dock, identity: identity)
    else {
      return false
    }

    guard let menuItem = await findNewWindowItem(in: menu, identity: identity) else {
      return false
    }

    let pressResult = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
    guard pressResult == .success else {
      logger.warning("[dock-menu] Failed to press new-window item: \(pressResult.rawValue)")
      return false
    }

    logger.info("[dock-menu] Clicked new-window item for '\(identity.bundleIdentifier)'")
    return true
  }

  private func resolveDockElements(for identity: AppIdentity) -> DockElements? {
    guard let dockPID = dockProcessID() else {
      logger.warning("[dock-menu] Dock process not found")
      return nil
    }

    let dockElement = AXUIElementCreateApplication(dockPID)
    guard let appElement = findAppElement(in: dockElement, identity: identity) else {
      logger.warning("[dock-menu] App '\(identity.bundleIdentifier)' not found in Dock")
      return nil
    }

    return DockElements(dock: dockElement, app: appElement)
  }

  private func revealMenu(for identity: AppIdentity, appElement: AXUIElement) -> Bool {
    let result = AXUIElementPerformAction(appElement, kAXShowMenuAction as CFString)
    guard result == .success else {
      logger.warning(
        "[dock-menu] Failed to show menu for '\(identity.bundleIdentifier)': \(result.rawValue)")
      return false
    }

    return true
  }

  @MainActor
  private func findVisibleMenu(
    appElement: AXUIElement,
    dockElement: AXUIElement,
    identity: AppIdentity
  ) async -> AXUIElement? {
    for delay in Self.menuSearchDelayNanoseconds {
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return nil
      }

      if let menu = firstDescendant(in: appElement, where: isMenu)
        ?? firstDescendant(in: dockElement, where: isMenu)
      {
        return menu
      }
    }

    logger.warning(
      "[dock-menu] Could not find menu for '\(identity.bundleIdentifier)' after retries")
    return nil
  }

  @MainActor
  private func findNewWindowItem(in menu: AXUIElement, identity: AppIdentity) async -> AXUIElement?
  {
    for attempt in 0..<Self.menuItemSearchAttempts {
      if let menuItem = firstDescendant(in: menu, where: isNewWindowItem) {
        return menuItem
      }

      if attempt + 1 < Self.menuItemSearchAttempts {
        do {
          try await Task.sleep(nanoseconds: Self.menuItemRetryDelayNanoseconds)
        } catch {
          return nil
        }
      }
    }

    logger.warning(
      "[dock-menu] new-window menu item not found for '\(identity.bundleIdentifier)'")
    return nil
  }

  private func dockProcessID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first?.processIdentifier
  }

  private func findAppElement(in dockElement: AXUIElement, identity: AppIdentity) -> AXUIElement? {
    for child in children(of: dockElement) ?? [] where isDockList(child) {
      if let appElement = firstDescendant(
        in: child, where: { matchesIdentity($0, identity: identity) })
      {
        return appElement
      }
    }

    return nil
  }

  private func firstDescendant(
    in root: AXUIElement,
    where matches: (AXUIElement) -> Bool
  ) -> AXUIElement? {
    if matches(root) {
      return root
    }

    for child in children(of: root) ?? [] {
      if let match = firstDescendant(in: child, where: matches) {
        return match
      }
    }

    return nil
  }

  private func matchesIdentity(_ element: AXUIElement, identity: AppIdentity) -> Bool {
    if let url = url(of: element), url.standardizedFileURL == identity.bundleURL {
      return true
    }

    if let identifier = stringAttribute(kAXIdentifierAttribute as CFString, of: element),
      identifier == identity.bundleIdentifier
    {
      return true
    }

    return false
  }

  private func isDockList(_ element: AXUIElement) -> Bool {
    stringAttribute(kAXRoleAttribute as CFString, of: element) == "AXList"
  }

  private func isMenu(_ element: AXUIElement) -> Bool {
    stringAttribute(kAXRoleAttribute as CFString, of: element) == "AXMenu"
  }

  private func isNewWindowItem(_ element: AXUIElement) -> Bool {
    guard stringAttribute(kAXRoleAttribute as CFString, of: element) == kAXMenuItemRole as String
    else {
      return false
    }

    if isCommandNMenuItem(element) {
      return true
    }

    return stringAttribute(kAXTitleAttribute as CFString, of: element) == Self.newWindowTitle
  }

  private func isCommandNMenuItem(_ element: AXUIElement) -> Bool {
    guard
      let command = stringAttribute(kAXMenuItemCmdCharAttribute as CFString, of: element),
      command.caseInsensitiveCompare("n") == .orderedSame
    else {
      return false
    }

    let modifiers: UInt32 =
      (attribute(kAXMenuItemCmdModifiersAttribute as CFString, of: element) as NSNumber?)?
      .uint32Value ?? Self.noCommandModifier
    return modifiers == Self.commandOnlyModifier
  }

  private func children(of element: AXUIElement) -> [AXUIElement]? {
    attribute(kAXChildrenAttribute as CFString, of: element)
  }

  private func stringAttribute(_ name: CFString, of element: AXUIElement) -> String? {
    attribute(name, of: element)
  }

  private func url(of element: AXUIElement) -> URL? {
    attribute(kAXURLAttribute as CFString, of: element)
  }

  private func attribute<T>(_ name: CFString, of element: AXUIElement) -> T? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name, &value)
    guard result == .success else {
      return nil
    }

    return value as? T
  }

  private static let newWindowTitle = "New Window"
  private static let commandOnlyModifier: UInt32 = 0
  private static let noCommandModifier: UInt32 = 1 << 3

  private static let menuSearchDelayNanoseconds: [UInt64] = [
    100_000_000,
    200_000_000,
    300_000_000,
    400_000_000,
    500_000_000,
  ]
  private static let menuItemSearchAttempts = 3
  private static let menuItemRetryDelayNanoseconds: UInt64 = 100_000_000
}

private struct DockElements {
  let dock: AXUIElement
  let app: AXUIElement
}
