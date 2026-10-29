import Foundation

/// Folder grants: the folders (besides the home folder) Strim may read, change and run commands in.
/// Control token only; the API/MCP token is refused on these routes.
public extension StrimRoutes {
    static let folders = "/v1/strim/folders"   // GET list; POST {path} grant; DELETE {path} revoke
}

/// Body of `POST`/`DELETE folders`.
public struct FolderRequest: Codable, Sendable, Equatable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// Reply of every `folders` call: the effective allowed roots (resolved paths).
public struct FolderList: Codable, Sendable, Equatable {
    public var folders: [String]
    /// The host's home folder (always allowed, cannot be revoked).
    public var home: String
    public var max: Int
    public init(folders: [String], home: String, max: Int = 64) { self.folders = folders; self.home = home; self.max = max }

    /// Roots other than the home folder: what the user granted.
    public var granted: [String] { folders.filter { $0 != home } }
}
