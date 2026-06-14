import CoreGraphics
import Foundation
import MachO
import OSLog
import ObjectiveC

/// Moves windows of other applications to the active Mission Control space.
///
/// macOS has no public API for this. Like yabai, three private SkyLight
/// mechanisms are tried, picked once at startup based on availability and OS
/// version:
///
/// 1. **Bridged operation** (macOS 15+/26): an `SLSBridgedMoveWindowsToManagedSpaceOperation`
///    executed via `SLSPerformAsynchronousBridgedWindowManagementOperation`. That
///    function has internal linkage, so it is located by scanning SkyLight's
///    Mach-O symbol table rather than `dlsym`.
/// 2. **Compat-ID workaround** (macOS 12.7+/13.6+/14.5+ without the bridged
///    operation): tag the active space with a temporary workspace ID via
///    `SLSSpaceSetCompatID`, re-point the windows at it with
///    `SLSSetWindowListWorkspace`, then clear the tag.
/// 3. **Direct move** (older macOS): `SLSMoveWindowsToManagedSpace`.
///
/// Everything is resolved at runtime so a missing symbol on a future macOS
/// degrades to a logged app-open failure instead of a launch-time link error.
struct SpaceMover: Sendable {
  private typealias MainConnectionID = @convention(c) () -> Int32
  private typealias CopyActiveDisplay = @convention(c) (Int32) -> Unmanaged<CFString>?
  private typealias ManagedDisplayCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
  private typealias PerformBridgedOperation = @convention(c) (UnsafeMutableRawPointer) -> Int64
  private typealias MsgSendAlloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
  private typealias MsgSendInitWithWindowsSpaceID =
    @convention(c) (
      UnsafeMutableRawPointer, Selector, CFArray, UInt64
    ) -> UnsafeMutableRawPointer?
  private typealias MsgSendRelease = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void
  private typealias MoveWindowsToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
  private typealias SpaceSetCompatID = @convention(c) (Int32, UInt64, Int32) -> Int32
  private typealias SetWindowListWorkspace =
    @convention(c) (
      Int32, UnsafePointer<UInt32>, Int32, Int32
    ) ->
    Int32

  private struct BridgedOperationFunctions: Sendable {
    let perform: PerformBridgedOperation
    let alloc: MsgSendAlloc
    let initWithWindowsSpaceID: MsgSendInitWithWindowsSpaceID
    let release: MsgSendRelease
  }

  private enum Mechanism: Sendable {
    case bridgedOperation(BridgedOperationFunctions)
    case compatID(set: SpaceSetCompatID, setWindowListWorkspace: SetWindowListWorkspace)
    case moveToManagedSpace(MoveWindowsToManagedSpace)

    var description: String {
      switch self {
      case .bridgedOperation: "bridged operation"
      case .compatID: "compat-ID workaround"
      case .moveToManagedSpace: "managed-space move"
      }
    }
  }

  private static let skylightPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
  private static let bridgedOperationClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"
  private static let performBridgedOperationSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperation"
    + "P47SLSAsynchronousBridgedWindowManagementOperation"

  // Arbitrary non-zero tag; only needs to be unique while a move is in flight.
  private static let compatID: Int32 = 0x6b62_6464

  private let logger: Logger
  private let verboseLogging: Bool
  private let mainConnectionID: MainConnectionID
  private let copyActiveDisplay: CopyActiveDisplay
  private let managedDisplayCurrentSpace: ManagedDisplayCurrentSpace
  private let mechanism: Mechanism

  init?(logger: Logger, verboseLogging: Bool = false) {
    guard let handle = dlopen(Self.skylightPath, RTLD_LAZY) else {
      logger.warning("[spaces] failed to load SkyLight framework")
      return nil
    }

    let resolve: (String) -> UnsafeMutableRawPointer? = { name in
      guard let address = dlsym(handle, name) else {
        logger.warning("[spaces] missing SkyLight symbol '\(name)'")
        return nil
      }

      return address
    }

    func symbol<T>(_ name: String, as type: T.Type) -> T? {
      resolve(name).map { unsafeBitCast($0, to: T.self) }
    }

    guard
      let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self),
      let copyActiveDisplay = symbol(
        "SLSCopyActiveMenuBarDisplayIdentifier", as: CopyActiveDisplay.self),
      let managedDisplayCurrentSpace = symbol(
        "SLSManagedDisplayGetCurrentSpace", as: ManagedDisplayCurrentSpace.self),
      let mechanism = Self.resolveMechanism(logger: logger, resolve: resolve)
    else {
      return nil
    }

    self.logger = logger
    self.verboseLogging = verboseLogging
    self.mainConnectionID = mainConnectionID
    self.copyActiveDisplay = copyActiveDisplay
    self.managedDisplayCurrentSpace = managedDisplayCurrentSpace
    self.mechanism = mechanism
    if verboseLogging {
      logger.debug("[spaces] using \(mechanism.description) to move windows")
    }
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

    switch mechanism {
    case .bridgedOperation(let functions):
      return performBridgedMove(windowIDs, to: space, using: functions)
    case .compatID(let setCompatID, let setWindowListWorkspace):
      return performCompatIDMove(
        windowIDs,
        to: space,
        connection: connection,
        setCompatID: setCompatID,
        setWindowListWorkspace: setWindowListWorkspace
      )
    case .moveToManagedSpace(let move):
      move(connection, Self.windowNumberArray(windowIDs), space)
      if verboseLogging {
        logger.debug("[spaces] requested managed-space move of \(windowIDs) to space \(space)")
      }
      return true
    }
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

  private func performBridgedMove(
    _ windowIDs: [CGWindowID],
    to space: UInt64,
    using functions: BridgedOperationFunctions
  ) -> Bool {
    guard let operationClass = NSClassFromString(Self.bridgedOperationClassName) else {
      logger.warning("[spaces] missing class '\(Self.bridgedOperationClassName)'")
      return false
    }

    guard let instance = functions.alloc(operationClass, sel_registerName("alloc")) else {
      logger.warning("[spaces] failed to allocate bridged move operation")
      return false
    }

    guard
      let operation = functions.initWithWindowsSpaceID(
        instance,
        sel_registerName("initWithWindows:spaceID:"),
        Self.windowNumberArray(windowIDs),
        space
      )
    else {
      logger.warning("[spaces] failed to initialize bridged move operation")
      return false
    }

    _ = functions.perform(operation)
    functions.release(operation, sel_registerName("release"))
    if verboseLogging {
      logger.debug("[spaces] requested bridged move of \(windowIDs) to space \(space)")
    }
    return true
  }

  private func performCompatIDMove(
    _ windowIDs: [CGWindowID],
    to space: UInt64,
    connection: Int32,
    setCompatID: SpaceSetCompatID,
    setWindowListWorkspace: SetWindowListWorkspace
  ) -> Bool {
    guard setCompatID(connection, space, Self.compatID) == 0 else {
      logger.warning("[spaces] failed to tag space \(space)")
      return false
    }

    defer {
      if setCompatID(connection, space, 0) != 0 {
        logger.warning("[spaces] failed to clear tag on space \(space)")
      }
    }

    let moved = windowIDs.withUnsafeBufferPointer { buffer in
      setWindowListWorkspace(
        connection, buffer.baseAddress!, Int32(buffer.count), Self.compatID)
    }
    guard moved == 0 else {
      logger.warning("[spaces] failed to move windows \(windowIDs) to space \(space)")
      return false
    }

    if verboseLogging {
      logger.debug("[spaces] moved windows \(windowIDs) to space \(space)")
    }
    return true
  }

  private static func resolveMechanism(
    logger: Logger,
    resolve: (String) -> UnsafeMutableRawPointer?
  ) -> Mechanism? {
    if let performAddress = localSymbol(
      image: skylightPath, name: performBridgedOperationSymbol),
      NSClassFromString(bridgedOperationClassName) != nil,
      let msgSend = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    {
      return .bridgedOperation(
        BridgedOperationFunctions(
          perform: unsafeBitCast(performAddress, to: PerformBridgedOperation.self),
          alloc: unsafeBitCast(msgSend, to: MsgSendAlloc.self),
          initWithWindowsSpaceID: unsafeBitCast(
            msgSend, to: MsgSendInitWithWindowsSpaceID.self),
          release: unsafeBitCast(msgSend, to: MsgSendRelease.self)
        )
      )
    }

    if requiresBridgedOperation() {
      logger.warning("[spaces] bridged move operation is unavailable on this macOS version")
      return nil
    }

    if needsCompatIDWorkaround() {
      guard
        let setCompatID = resolve("SLSSpaceSetCompatID"),
        let setWindowListWorkspace = resolve("SLSSetWindowListWorkspace")
      else {
        return nil
      }

      return .compatID(
        set: unsafeBitCast(setCompatID, to: SpaceSetCompatID.self),
        setWindowListWorkspace: unsafeBitCast(
          setWindowListWorkspace, to: SetWindowListWorkspace.self)
      )
    }

    guard let move = resolve("SLSMoveWindowsToManagedSpace") else {
      return nil
    }

    return .moveToManagedSpace(unsafeBitCast(move, to: MoveWindowsToManagedSpace.self))
  }

  // SLSMoveWindowsToManagedSpace and SLSSpaceSetCompatID stopped working for
  // external connections in macOS 12.7/13.6/14.5 and 15+ respectively; this
  // mirrors yabai's version gates.
  private static func needsCompatIDWorkaround() -> Bool {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    switch version.majorVersion {
    case ..<12:
      return false
    case 12:
      return version.minorVersion >= 7
    case 13:
      return version.minorVersion >= 6
    case 14:
      return version.minorVersion >= 5
    default:
      return true
    }
  }

  private static func requiresBridgedOperation() -> Bool {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
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
