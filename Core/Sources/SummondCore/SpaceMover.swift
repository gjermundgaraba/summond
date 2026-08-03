import CoreGraphics
import Foundation
import MachO
import OSLog
import ObjectiveC

/// Moves windows of other applications to the active Mission Control space.
///
/// macOS has no public API for this. The SkyLight technique used here — a
/// `SLSBridgedMoveWindowsToManagedSpaceOperation` executed via
/// `SLSPerformAsynchronousBridgedWindowManagementOperation` — was informed by
/// yabai's window-management code (see THIRD_PARTY_NOTICES.md). It works on
/// macOS 26 without disabling SIP.
///
/// Everything is resolved at runtime: `SLSPerformAsynchronousBridgedWindowManagementOperation`
/// has internal linkage, so it is located by scanning SkyLight's Mach-O symbol
/// table rather than `dlsym`. A missing symbol or class on a future macOS
/// degrades to a logged app-open failure instead of a launch-time link error.
struct SpaceMover: Sendable {
  private typealias MainConnectionID = @convention(c) () -> Int32
  private typealias CopyActiveDisplay = @convention(c) (Int32) -> Unmanaged<CFString>?
  private typealias ManagedDisplayCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
  private typealias CopySpacesForWindows =
    @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
  private typealias PerformBridgedOperation = @convention(c) (UnsafeMutableRawPointer) -> Int64
  private typealias MsgSendAlloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
  private typealias MsgSendInitWithWindowsSpaceID =
    @convention(c) (
      UnsafeMutableRawPointer, Selector, CFArray, UInt64
    ) -> UnsafeMutableRawPointer?
  private typealias MsgSendRelease = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void

  private struct BridgedOperation: Sendable {
    let perform: PerformBridgedOperation
    let alloc: MsgSendAlloc
    let initWithWindowsSpaceID: MsgSendInitWithWindowsSpaceID
    let release: MsgSendRelease
  }

  private static let skylightPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
  private static let bridgedOperationClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"
  private static let performBridgedOperationSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperation"
    + "P47SLSAsynchronousBridgedWindowManagementOperation"

  // `SLSCopySpacesForWindows` selector: include every space the given windows
  // occupy (current and others), matching yabai's usage.
  private static let allSpacesSelector: Int32 = 0x7

  private let logger: Logger
  private let verboseLogging: VerboseLoggingState
  private let mainConnectionID: MainConnectionID
  private let copyActiveDisplay: CopyActiveDisplay
  private let managedDisplayCurrentSpace: ManagedDisplayCurrentSpace
  private let copySpacesForWindows: CopySpacesForWindows
  private let bridgedOperation: BridgedOperation

  init?(logger: Logger, verboseLogging: VerboseLoggingState) {
    guard let handle = dlopen(Self.skylightPath, RTLD_LAZY) else {
      logger.warning("[spaces] failed to load SkyLight framework")
      return nil
    }

    func symbol<T>(_ name: String, as type: T.Type) -> T? {
      guard let address = dlsym(handle, name) else {
        logger.warning("[spaces] missing SkyLight symbol '\(name)'")
        return nil
      }
      return unsafeBitCast(address, to: T.self)
    }

    guard
      let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self),
      let copyActiveDisplay = symbol(
        "SLSCopyActiveMenuBarDisplayIdentifier", as: CopyActiveDisplay.self),
      let managedDisplayCurrentSpace = symbol(
        "SLSManagedDisplayGetCurrentSpace", as: ManagedDisplayCurrentSpace.self),
      let copySpacesForWindows = symbol(
        "SLSCopySpacesForWindows", as: CopySpacesForWindows.self),
      let bridgedOperation = Self.resolveBridgedOperation(logger: logger)
    else {
      return nil
    }

    self.logger = logger
    self.verboseLogging = verboseLogging
    self.mainConnectionID = mainConnectionID
    self.copyActiveDisplay = copyActiveDisplay
    self.managedDisplayCurrentSpace = managedDisplayCurrentSpace
    self.copySpacesForWindows = copySpacesForWindows
    self.bridgedOperation = bridgedOperation
  }

  func moveWindowsToActiveSpace(_ windowIDs: [CGWindowID]) -> Bool {
    guard !windowIDs.isEmpty else {
      return false
    }

    let connection = mainConnectionID()
    guard let space = activeSpace(connection: connection), space != 0 else {
      logger.warning("[spaces] failed to determine the active space")
      return false
    }

    return performBridgedMove(windowIDs, to: space)
  }

  /// The current space of the display that owns the menu bar. This is the
  /// space the user is looking at; `SLSGetActiveSpace` can lag behind it on
  /// multi-display setups, so the managed-display lookup is used instead.
  private func activeSpace(connection: Int32) -> UInt64? {
    guard let display = copyActiveDisplay(connection)?.takeRetainedValue() else {
      return nil
    }

    return managedDisplayCurrentSpace(connection, display)
  }

  /// Whether any of the given windows occupies the active Mission Control space
  /// — the same space `moveWindowsToActiveSpace` targets. Unlike a CGWindowList
  /// onscreen check this is display-aware: with "Displays have separate Spaces"
  /// enabled, a window merely visible on another display does not count.
  func anyWindowOnActiveSpace(_ windowIDs: [CGWindowID]) -> Bool {
    guard !windowIDs.isEmpty else {
      return false
    }

    let connection = mainConnectionID()
    guard let active = activeSpace(connection: connection), active != 0 else {
      return false
    }

    guard
      let spaces = copySpacesForWindows(
        connection, Self.allSpacesSelector, Self.windowNumberArray(windowIDs)
      )?.takeRetainedValue() as? [NSNumber]
    else {
      return false
    }

    return spaces.contains { $0.uint64Value == active }
  }

  private func performBridgedMove(_ windowIDs: [CGWindowID], to space: UInt64) -> Bool {
    guard let operationClass = NSClassFromString(Self.bridgedOperationClassName) else {
      logger.warning("[spaces] missing class '\(Self.bridgedOperationClassName)'")
      return false
    }

    guard let instance = bridgedOperation.alloc(operationClass, sel_registerName("alloc")) else {
      logger.warning("[spaces] failed to allocate bridged move operation")
      return false
    }

    guard
      let operation = bridgedOperation.initWithWindowsSpaceID(
        instance,
        sel_registerName("initWithWindows:spaceID:"),
        Self.windowNumberArray(windowIDs),
        space
      )
    else {
      logger.warning("[spaces] failed to initialize bridged move operation")
      return false
    }

    _ = bridgedOperation.perform(operation)
    bridgedOperation.release(operation, sel_registerName("release"))
    if verboseLogging.isEnabled {
      logger.debug("[spaces] requested bridged move of \(windowIDs) to space \(space)")
    }
    return true
  }

  private static func resolveBridgedOperation(logger: Logger) -> BridgedOperation? {
    guard
      let performAddress = localSymbol(image: skylightPath, name: performBridgedOperationSymbol),
      NSClassFromString(bridgedOperationClassName) != nil,
      let msgSend = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    else {
      logger.warning("[spaces] bridged move operation is unavailable on this macOS version")
      return nil
    }

    return BridgedOperation(
      perform: unsafeBitCast(performAddress, to: PerformBridgedOperation.self),
      alloc: unsafeBitCast(msgSend, to: MsgSendAlloc.self),
      initWithWindowsSpaceID: unsafeBitCast(msgSend, to: MsgSendInitWithWindowsSpaceID.self),
      release: unsafeBitCast(msgSend, to: MsgSendRelease.self)
    )
  }

  private static func windowNumberArray(_ windowIDs: [CGWindowID]) -> CFArray {
    let numbers: [CFNumber] = windowIDs.map { windowID in
      var value = Int32(bitPattern: windowID)
      return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value)
    }

    return numbers as CFArray
  }

  /// Finds a symbol in a loaded image by scanning its Mach-O symbol table,
  /// which (unlike `dlsym`) also sees symbols with internal linkage.
  private static func localSymbol(
    image imagePath: String,
    name symbolName: String
  ) -> UnsafeMutableRawPointer? {
    for index in 0..<_dyld_image_count() {
      guard
        let imageName = _dyld_get_image_name(index),
        String(cString: imageName) == imagePath,
        let header = _dyld_get_image_header(index)
      else {
        continue
      }

      return localSymbol(
        header: header,
        slide: _dyld_get_image_vmaddr_slide(index),
        name: symbolName
      )
    }

    return nil
  }

  private static func localSymbol(
    header: UnsafePointer<mach_header>,
    slide: Int,
    name symbolName: String
  ) -> UnsafeMutableRawPointer? {
    var linkeditSegment: segment_command_64?
    var symtabCommand: symtab_command?

    let commandCount = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
      $0.pointee.ncmds
    }
    var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
    for _ in 0..<commandCount {
      let command = cursor.assumingMemoryBound(to: load_command.self).pointee
      if command.cmd == LC_SEGMENT_64 {
        let segment = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
        let segmentName = withUnsafeBytes(of: segment.segname) { raw in
          String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if segmentName == SEG_LINKEDIT {
          linkeditSegment = segment
        }
      } else if command.cmd == LC_SYMTAB {
        symtabCommand = cursor.assumingMemoryBound(to: symtab_command.self).pointee
      }

      cursor += Int(command.cmdsize)
    }

    guard let linkeditSegment, let symtabCommand else {
      return nil
    }

    let linkeditBase =
      UInt64(bitPattern: Int64(slide)) &+ linkeditSegment.vmaddr &- linkeditSegment.fileoff
    guard
      let stringTable = UnsafeRawPointer(
        bitPattern: UInt(linkeditBase &+ UInt64(symtabCommand.stroff))),
      let symbolTable = UnsafeRawPointer(
        bitPattern: UInt(linkeditBase &+ UInt64(symtabCommand.symoff)))
    else {
      return nil
    }

    for index in 0..<Int(symtabCommand.nsyms) {
      let entry = (symbolTable + index * MemoryLayout<nlist_64>.size)
        .assumingMemoryBound(to: nlist_64.self).pointee
      let entryName = String(
        cString: (stringTable + Int(entry.n_un.n_strx)).assumingMemoryBound(to: CChar.self))
      if entryName == symbolName {
        return UnsafeMutableRawPointer(
          bitPattern: UInt(entry.n_value) &+ UInt(bitPattern: slide))
      }
    }

    return nil
  }
}
