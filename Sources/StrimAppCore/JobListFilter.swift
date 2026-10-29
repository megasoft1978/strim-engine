import Foundation
import StrimAPI

/// Default Jobs-list filter: active jobs and anything that ended in the last 24 h; the rest sits behind "show all".
public enum JobListFilter {
    public static let window: TimeInterval = 24 * 3600

    public struct Result: Equatable, Sendable {
        public var shown: [JobSummary]
        public var total: Int
        public var active: Int
        public var hidden: Int { total - shown.count }
    }

    public static func apply(_ jobs: [JobSummary], now: Date, showAll: Bool, keep: String? = nil) -> Result {
        let t = now.timeIntervalSince1970
        let active = jobs.filter { !$0.status.isFinished }.count
        guard !showAll else { return Result(shown: jobs, total: jobs.count, active: active) }
        let shown = jobs.filter { j in
            !j.status.isFinished || j.id == keep || t - (j.finished ?? j.started) <= window
        }
        return Result(shown: shown, total: jobs.count, active: active)
    }
}

public extension JobStatusDTO {
    var isFinished: Bool { [.done, .failed, .cancelled, .limit].contains(self) }
}
