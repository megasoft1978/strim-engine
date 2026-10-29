import Foundation
import StrimAPI
import StrimHarness
import StrimHost
import StrimHTTP
import StrimServer

/// Folder grants: `GET/POST/DELETE /v1/strim/folders`. These routes go through `ControlGuard.check(status: false)`,
/// so only the control token (the menu-bar app) passes; the API/MCP bearer token gets 403 and no token 401. An agent,
/// MCP client or prompt-injected tool call therefore cannot widen its own reach.
extension StrimControlPlane {
    func registerFolders(on server: StrimOpenAIServer) {
        add(server, "GET", StrimRoutes.folders, write: false) { c, _ in try c.folderList() }
        add(server, "POST", StrimRoutes.folders, write: true) { c, req in try c.grantFolder(req) }
        add(server, "DELETE", StrimRoutes.folders, write: true) { c, req in try c.revokeFolder(req) }
    }

    private func grantsOrThrow() throws -> FolderGrants {
        guard let g = policy.grants else { throw ControlError.notImplemented("folder grants are not available on this host") }
        return g
    }

    private func reply(_ g: FolderGrants, _ roots: [String]) throws -> Reply {
        try .json(FolderList(folders: roots, home: g.home, max: FolderGrants.maxRoots))
    }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as FolderGrantError {
            switch e.kind {
            case .badRequest: throw ControlError.badRequest(e.message)
            case .forbidden: throw ControlError.forbidden(e.message)
            case .notFound: throw ControlError.notFound(e.message)
            case .conflict: throw ControlError.conflict(e.message)
            case .io: throw ControlError.internalError(e.message)
            }
        }
    }

    func folderList() throws -> Reply {
        let g = try grantsOrThrow()
        return try reply(g, g.roots)
    }

    func grantFolder(_ req: Request) throws -> Reply {
        let g = try grantsOrThrow()
        let b = try ControlJSON.decode(FolderRequest.self, from: req.body)
        let roots = try mapped { try g.grant(b.path) }
        FileHandle.standardError.write(Data("control: folder grant \(Sanitize.text(b.path, limit: 300))\n".utf8))
        return try reply(g, roots)
    }

    func revokeFolder(_ req: Request) throws -> Reply {
        let g = try grantsOrThrow()
        let b = try ControlJSON.decode(FolderRequest.self, from: req.body)
        let roots = try mapped { try g.revoke(b.path) }
        FileHandle.standardError.write(Data("control: folder revoke \(Sanitize.text(b.path, limit: 300))\n".utf8))
        return try reply(g, roots)
    }
}
