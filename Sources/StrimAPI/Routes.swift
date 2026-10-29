import Foundation

/// Route constants of the control API. All routes require the bearer token and are loopback-only.
public enum StrimRoutes {
    public static let apiVersion = 1
    public static let status = "/v1/strim/status"            // GET
    public static let events = "/v1/strim/events"            // GET, text/event-stream
    public static let load = "/v1/strim/load"                // POST (write)
    public static let unload = "/v1/strim/unload"            // POST (write)
    public static let jobs = "/v1/strim/jobs"                // GET list; GET /v1/strim/jobs/{id}
    public static let jobApprove = "/v1/strim/jobs/approve"  // POST (write)
    public static let chatOpen = "/v1/strim/chat/open"       // POST (write)
    public static let chatAppend = "/v1/strim/chat/append"   // POST (write)
    public static let chatCancel = "/v1/strim/chat/cancel"   // POST (write)
    public static let chatClose = "/v1/strim/chat/close"     // POST (write); body {"session_id"}

    /// Path for one job: `/v1/strim/jobs/{id}`.
    public static func job(_ id: String) -> String { jobs + "/" + id }
}
