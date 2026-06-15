import Foundation
import OSLog
import Security

public enum CodeSigningIdentity {
  public static func selfTeamIdentifier(logger: Logger) -> String? {
    var secCode: SecCode?
    let selfStatus = SecCodeCopySelf(SecCSFlags(), &secCode)
    guard selfStatus == errSecSuccess, let secCode else {
      logger.warning("SecCodeCopySelf failed: \(selfStatus)")
      return nil
    }

    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(secCode, SecCSFlags(), &staticCode)
    guard staticStatus == errSecSuccess, let staticCode else {
      logger.warning("SecCodeCopyStaticCode failed: \(staticStatus)")
      return nil
    }

    var signingInformation: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    )
    guard infoStatus == errSecSuccess, let signingInformation else {
      logger.warning("SecCodeCopySigningInformation failed: \(infoStatus)")
      return nil
    }

    let info = signingInformation as NSDictionary
    return info[kSecCodeInfoTeamIdentifier as String] as? String
  }
}
