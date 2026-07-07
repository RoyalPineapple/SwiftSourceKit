#!/usr/bin/env swift

import Foundation

let repository = "https://raw.githubusercontent.com/swiftlang/swift"
let defaultCommit = "0ea5523c8c90706d7da2478c7e950eaa62414b20"

let commit = CommandLine.arguments.dropFirst().first ?? defaultCommit
let files = [
    (
        upstream: "tools/SourceKit/tools/sourcekitd/include/sourcekitd/sourcekitd.h",
        local: "Tests/Fixtures/sourcekitd/sourcekitd.h"
    ),
    (
        upstream: "utils/gyb_sourcekit_support/UIDs.py",
        local: "Tests/Fixtures/sourcekit/UIDs.py"
    ),
]

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "SwiftSourceKitFixtureUpdate",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
}

for file in files {
    let url = "\(repository)/\(commit)/\(file.upstream)"
    try run("/usr/bin/curl", ["-fL", url, "-o", file.local])
}

try run("/usr/bin/swift", [
    "Tools/generate-sourcekitd-shim.swift",
    "--sourcekitd-header", "Tests/Fixtures/sourcekitd/sourcekitd.h",
    "--output", "Sources/CSourceKitDShim",
])
try run("/usr/bin/swift", ["Tools/generate-sourcekit-uid-constants.swift"])

let headerProvenance = """
Generated from:
https://github.com/swiftlang/swift/blob/\(commit)/tools/SourceKit/tools/sourcekitd/include/sourcekitd/sourcekitd.h

Pinned local fixture:
Tests/Fixtures/sourcekitd/sourcekitd.h

Regenerate with:
swift Tools/generate-sourcekitd-shim.swift --sourcekitd-header Tests/Fixtures/sourcekitd/sourcekitd.h --output Sources/CSourceKitDShim

Verify with:
swift Tools/generate-sourcekitd-shim.swift --verify --sourcekitd-header Tests/Fixtures/sourcekitd/sourcekitd.h --output Sources/CSourceKitDShim

The generated shim must be regenerated when the loaded sourcekitd runtime comes
from a different Swift/Xcode toolchain. Xcode ships sourcekitd.framework, but
does not necessarily ship sourcekitd.h beside it.
""" + "\n"

let uidProvenance = """
Pinned upstream Swift sourcekitd protocol UID source.

Repository: https://github.com/swiftlang/swift
Commit: \(commit)
Source: utils/gyb_sourcekit_support/UIDs.py
Fixture: Tests/Fixtures/sourcekit/UIDs.py

Refresh by replacing the fixture from a chosen Swift commit and running:

swift Tools/generate-sourcekit-uid-constants.swift
swift Tools/generate-sourcekit-uid-constants.swift --verify
""" + "\n"

try headerProvenance.write(
    toFile: "Sources/CSourceKitDShim/sourcekitd-header-provenance.txt",
    atomically: true,
    encoding: .utf8
)
try uidProvenance.write(
    toFile: "Sources/SwiftSourceKit/sourcekit-uid-provenance.txt",
    atomically: true,
    encoding: .utf8
)
