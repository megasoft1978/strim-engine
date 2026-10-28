import Foundation
import StrimControl
import StrimServer

// strim control-token [--token-file PATH]
//
// Prints the PATH of the control token file (never the token). The menu-bar app reads it from there.

func runControlToken(_ args: [String]) {
    var apiTokenPath = TokenStore.defaultPath
    var i = 2
    while i < args.count {
        if args[i] == "--token-file", i + 1 < args.count { apiTokenPath = args[i + 1]; i += 1 }
        else if args[i].hasPrefix("--token-file=") { apiTokenPath = String(args[i].dropFirst("--token-file=".count)) }
        else { FileHandle.standardError.write(Data("usage: strim control-token [--token-file PATH]\n".utf8)); exit(2) }
        i += 1
    }
    print(ControlToken.path(besideAPITokenAt: apiTokenPath))
}
