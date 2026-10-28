import Foundation
import StrimServer

/// The control API token: a second secret, distinct from the API/MCP token, accepted only on `/v1/strim/*`.
/// Lives next to the API token (`~/.strim/control-token` by default), 0600, 32 random bytes as hex, created at
/// `strim serve` start when missing. Rotate by deleting the file and restarting the host.
public enum ControlToken {
    public static let fileName = "control-token"

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strim/\(fileName)").path
    }

    /// `<dir of the API token file>/control-token`.
    public static func path(besideAPITokenAt apiTokenPath: String) -> String {
        URL(fileURLWithPath: apiTokenPath).deletingLastPathComponent().appendingPathComponent(fileName).path
    }

    public static func loadOrCreate(path: String) throws -> String { try TokenStore.loadOrCreate(path: path) }
}
