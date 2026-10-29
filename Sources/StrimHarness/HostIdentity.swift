import Foundation
import CryptoKit

/// Stable identity for the owner of job processes, scoped to a resolved host state directory.
public enum HostIdentity {
    public static func id(for root: URL) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strim") }
}
