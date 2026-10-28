import Foundation
import StrimSoak

// strim soak [--duration MIN=30] [--arms both|claude|codex] [--model DIR] [--head DIR] [--out DIR] ...
//   Real Claude Code and Codex CLI clients against `strim serve` (Sources/StrimSoak). Run `strim soak --help`.
//   strim soak --list-tasks | --summarize DIR

/// `strim soak` entry point. args is the full argv (args[1] is the subcommand name).
enum SoakCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        SoakEntry.run(Array(args.dropFirst(2)), executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
                      cwd: FileManager.default.currentDirectoryPath, home: NSHomeDirectory(),
                      env: ProcessInfo.processInfo.environment)
    }
}
