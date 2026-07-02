import Foundation
import SwiftSourceKit

@main
struct SourceKitDProbe {
    static func main() async {
        do {
            let libraryPath = try parseLibraryPath()
            let client = try SourceKitClient(libraryPath: libraryPath)
            let version = try await client.compilerVersion()
            guard version.major != nil else {
                throw ProbeError("compiler version response did not include key.version_major")
            }

            print("SourceKitD probe passed")
        } catch {
            fputs("SourceKitD probe failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseLibraryPath() throws -> String? {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            return nil
        }
        guard arguments.first == "--library-path", arguments.count == 2 else {
            throw ProbeError("usage: SourceKitDProbe [--library-path <path>]")
        }
        return arguments.removeLast()
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
