import Foundation
import Testing
@testable import SwiftSourceKit

@Suite("SwiftSourceKit")
struct SwiftSourceKitTests {
    @Test
    func cursorInfoRequestBuildsTypedSourceKitValue() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Example.swift")
        let sdk = FileManager.default.temporaryDirectory.appendingPathComponent("SDK")
        let request = CursorInfoRequest(
            location: SourceKitLocation(file: file, byteOffset: 12),
            context: SourceKitBuildContext(compilerArguments: ["-sdk", sdk.path])
        )

        #expect(request.value == .dictionary([
            .Key.request: .uid(.Request.cursorInfo),
            .Key.name: .string(file.path),
            .Key.sourceFile: .string(file.path),
            .Key.offset: .int64(12),
            .Key.compilerArguments: .array([.string("-sdk"), .string(sdk.path)]),
        ]))
    }

    @Test
    func sourceKitResponseReadsFullValueSurface() {
        let response = SourceKitResponse(value: .dictionary([
            "null": .null,
            "bool": .bool(true),
            "double": .double(1.5),
            "data": .data(Data([1, 2, 3])),
            "array": .array([.string("value")]),
            "dictionary": .dictionary(["child": .int64(7)]),
        ]))

        #expect(response.dictionaryValue(for: "null") == .null)
        #expect(response.bool(for: "bool") == true)
        #expect(response.double(for: "double") == 1.5)
        #expect(response.data(for: "data") == Data([1, 2, 3]))
        #expect(response.array(for: "array") == [.string("value")])
        #expect(response.dictionary(for: "dictionary") == ["child": .int64(7)])
    }

    @Test
    func clientLoadsSourceKitDWhenAvailable() throws {
        do {
            _ = try SourceKitClient(libraryPath: sourceKitDPath())
        } catch SourceKitError.sourceKitUnavailable {
            return
        }
    }

    @Test
    func compilerVersionQueriesSourceKitD() async throws {
        let client: SourceKitClient
        do {
            client = try SourceKitClient(libraryPath: sourceKitDPath())
        } catch SourceKitError.sourceKitUnavailable {
            return
        }

        let version = try await client.compilerVersion()

        #expect(version.major != nil)
    }

    @Test
    func rawSendQueriesSourceKitDWithoutTypedRequestWrapper() async throws {
        let client: SourceKitClient
        do {
            client = try SourceKitClient(libraryPath: sourceKitDPath())
        } catch SourceKitError.sourceKitUnavailable {
            return
        }

        let value = try await client.send(.dictionary([
            .Key.request: .uid(.Request.compilerVersion),
        ]))

        guard case .dictionary(let dictionary) = value else {
            Issue.record("Expected dictionary response")
            return
        }
        #expect(dictionary[.Key.versionMajor] != nil)
    }

    @Test
    func fakeRuntimeDecodesFullSourceKitValueSurface() async throws {
        let client = try SourceKitClient(libraryPath: try fakeSourceKitDPath())

        let value = try await client.send(.dictionary([
            .Key.request: .uid("swift-sourcekit-test.full_surface"),
        ]))

        guard case .dictionary(let dictionary) = value else {
            Issue.record("Expected dictionary response")
            return
        }
        #expect(dictionary["null"] == .null)
        #expect(dictionary["int64"] == .int64(42))
        #expect(dictionary["string"] == .string("hello"))
        #expect(dictionary["uid"] == .uid("uid.value"))
        #expect(dictionary["bool"] == .bool(true))
        #expect(dictionary["double"] == .double(1.5))
        #expect(dictionary["data"] == .data(Data([1, 2, 3])))
        #expect(dictionary["array"] == .array([.string("first")]))
        #expect(dictionary["dictionary"] == .dictionary(["nested.int": .int64(7)]))
    }

    @Test
    func fakeRuntimeValidatesRequestEncodingAndPartialRequestCleanup() async throws {
        let client = try SourceKitClient(libraryPath: try fakeSourceKitDPath())

        do {
            _ = try await client.send(.dictionary([
                .Key.request: .uid("swift-sourcekit-test.encoding"),
                "nested": .array([.string("kept"), .bool(true)]),
            ]))
            Issue.record("Expected invalid request")
        } catch SourceKitError.invalidRequest {
        }

        let liveValues = try await client.send(.dictionary([
            .Key.request: .uid("swift-sourcekit-test.live_values"),
        ]))
        #expect(liveValues == .int64(2))

        let encoded = try await client.send(.dictionary([
            .Key.request: .uid("swift-sourcekit-test.encoding"),
            "name": .string("root"),
            "uid": .uid("uid.request"),
            "array": .array([
                .string("first"),
                .int64(2),
                .dictionary(["deep": .string("value")]),
            ]),
            "nested": .dictionary(["child": .int64(9)]),
        ]))
        #expect(encoded == .string("ok"))
    }

    @Test
    func fakeRuntimeMapsErrorAndDecodeFailures() async throws {
        let client = try SourceKitClient(libraryPath: try fakeSourceKitDPath())

        do {
            _ = try await client.send(.dictionary([
                .Key.request: .uid("swift-sourcekit-test.error"),
            ]))
            Issue.record("Expected sourcekitd error")
        } catch SourceKitError.requestFailed(let kind, let description) {
            #expect(kind == 22)
            #expect(description == "synthetic sourcekitd error")
        }

        do {
            _ = try await client.send(.dictionary([
                .Key.request: .uid("swift-sourcekit-test.null_response"),
            ]))
            Issue.record("Expected null response failure")
        } catch SourceKitError.requestFailed(let kind, let description) {
            #expect(kind == -1)
            #expect(description == "sourcekitd returned no response")
        }

        do {
            _ = try await client.send(.dictionary([
                .Key.request: .uid("swift-sourcekit-test.unsupported_variant"),
            ]))
            Issue.record("Expected unsupported variant failure")
        } catch SourceKitError.responseDecodeFailed(let message) {
            #expect(message.contains("unsupported sourcekitd variant type 99"))
        }
    }

    @Test
    func fakeRuntimeHandlesNullStringAndDataPointers() async throws {
        let client = try SourceKitClient(libraryPath: try fakeSourceKitDPath())

        let value = try await client.send(.dictionary([
            .Key.request: .uid("swift-sourcekit-test.null_string_data"),
        ]))

        guard case .dictionary(let dictionary) = value else {
            Issue.record("Expected dictionary response")
            return
        }
        #expect(dictionary["string"] == .string(""))
        #expect(dictionary["data"] == .data(Data()))
    }

    @Test
    func missingFakeRuntimeSymbolFailsBeforeRequestsAreSent() throws {
        do {
            _ = try SourceKitClient(libraryPath: try fakeSourceKitDPath(omittingSend: true))
            Issue.record("Expected missing symbol failure")
        } catch SourceKitError.missingSymbol(let symbol) {
            #expect(symbol == "sourcekitd_send_request_sync")
        }
    }

    @Test
    func unsupportedRequestValuesFailBeforeSourceKitRequest() async throws {
        let client: SourceKitClient
        do {
            client = try SourceKitClient(libraryPath: sourceKitDPath())
        } catch SourceKitError.sourceKitUnavailable {
            return
        }

        for value in [SourceKitValue.null, .bool(true), .double(1), .data(Data([1]))] {
            do {
                _ = try await client.send(value)
                Issue.record("Expected invalid request for \(value)")
            } catch SourceKitError.invalidRequest(let message) {
                #expect(message.contains("sourcekitd.h exposes no request constructor/setter"))
            }
        }
    }

    @Test
    func cursorInfoQueriesSourceKitDForTinySwiftFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Example.swift")
        let source = """
        let answer = "forty two"
        print(answer)
        """
        try source.write(to: file, atomically: true, encoding: .utf8)

        guard let offset = source.utf8Offset(of: "answer)") else {
            Issue.record("Could not find cursor token in fixture")
            return
        }

        let client: SourceKitClient
        do {
            client = try SourceKitClient(libraryPath: sourceKitDPath())
        } catch SourceKitError.sourceKitUnavailable {
            return
        }

        let cursorInfo = try await client.cursorInfo(
            at: SourceKitLocation(file: file, byteOffset: Int64(offset)),
            context: SourceKitBuildContext(
                compilerArguments: [
                    "-sdk", try macOSSDKPath(),
                    "-target", "arm64-apple-macosx15.0",
                    file.path,
                ]
            )
        )

        #expect(cursorInfo.name?.contains("answer") == true)
    }

    private func sourceKitDPath() -> String? {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        return developerDirectory.map {
            $0 + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/sourcekitd"
        }
    }

    private func macOSSDKPath() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func fakeSourceKitDPath(omittingSend: Bool = false) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let output = directory.appendingPathComponent("libFakeSourceKitD.dylib")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try clangPath())
    process.arguments = [
        "-dynamiclib",
        fixturePath("FakeSourceKitD/sourcekitd.c"),
        "-o",
        output.path,
    ] + (omittingSend ? ["-DFAKE_SOURCEKITD_OMIT_SEND_REQUEST_SYNC"] : [])
    let errorOutput = Pipe()
    process.standardError = errorOutput
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let data = errorOutput.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
        throw SourceKitError.sourceKitUnavailable("fake sourcekitd build failed: \(message)")
    }

    return output.path
}

private func clangPath() throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "clang"]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func fixturePath(_ relativePath: String) -> String {
    repoRoot().appendingPathComponent("Tests/Fixtures").appendingPathComponent(relativePath).path
}

private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private extension String {
    func utf8Offset(of needle: String) -> Int? {
        guard let range = range(of: needle) else {
            return nil
        }
        return utf8.distance(from: utf8.startIndex, to: range.lowerBound.samePosition(in: utf8)!)
    }
}
