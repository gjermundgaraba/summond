import Foundation

public enum XPCBridgeError: Error, Equatable, LocalizedError, Sendable {
  case timedOut(operation: String)
  case connectionInterrupted(operation: String)
  case connectionInvalidated(operation: String)
  case cancelled(operation: String)

  public var errorDescription: String? {
    switch self {
    case .timedOut(let operation):
      "\(operation) timed out."
    case .connectionInterrupted(let operation):
      "\(operation) was interrupted."
    case .connectionInvalidated(let operation):
      "\(operation) was invalidated."
    case .cancelled(let operation):
      "\(operation) was cancelled."
    }
  }
}

public final class XPCOneShotResponder<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private let onResume: @Sendable () -> Void

  public init(
    continuation: CheckedContinuation<Value, any Error>,
    operation: String,
    timeoutNanoseconds: UInt64?,
    onResume: @escaping @Sendable () -> Void = {}
  ) {
    self.continuation = continuation
    self.onResume = onResume

    if let timeoutNanoseconds {
      timeoutTask = Task { [weak self] in
        do {
          try await Task.sleep(nanoseconds: timeoutNanoseconds)
        } catch {
          return
        }
        self?.resume(throwing: XPCBridgeError.timedOut(operation: operation))
      }
    }
  }

  public func resume(returning value: Value) {
    guard let continuation = takeContinuation() else {
      return
    }
    continuation.resume(returning: value)
  }

  public func resume(throwing error: any Error) {
    guard let continuation = takeContinuation() else {
      return
    }
    continuation.resume(throwing: error)
  }

  private func takeContinuation() -> CheckedContinuation<Value, any Error>? {
    let continuation = lock.withLock {
      let continuation = self.continuation
      self.continuation = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      return continuation
    }

    if continuation != nil {
      onResume()
    }
    return continuation
  }
}

public enum XPCAsyncBridge {
  public static let defaultTimeoutNanoseconds: UInt64 = 5_000_000_000

  public static func perform<Value: Sendable>(
    operation: String,
    timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
    onResume: @escaping @Sendable () -> Void = {},
    _ body: @escaping @Sendable (XPCOneShotResponder<Value>) -> Void
  ) async throws -> Value {
    let responderBox = XPCOneShotResponderBox<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let responder = XPCOneShotResponder(
          continuation: continuation,
          operation: operation,
          timeoutNanoseconds: timeoutNanoseconds,
          onResume: onResume
        )
        responderBox.set(responder)
        if Task.isCancelled {
          responder.resume(throwing: XPCBridgeError.cancelled(operation: operation))
          return
        }
        body(responder)
      }
    } onCancel: {
      responderBox.resume(throwing: XPCBridgeError.cancelled(operation: operation))
    }
  }
}

private final class XPCOneShotResponderBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var responder: XPCOneShotResponder<Value>?

  func set(_ responder: XPCOneShotResponder<Value>) {
    lock.withLock {
      self.responder = responder
    }
  }

  func resume(throwing error: any Error) {
    lock.withLock { responder }?.resume(throwing: error)
  }
}
