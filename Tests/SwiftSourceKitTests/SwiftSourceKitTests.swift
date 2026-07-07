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
            .request: .uid(.cursorInfo),
            .name: .string(file.path),
            .sourceFile: .string(file.path),
            .offset: .int64(12),
            .compilerArguments: .array([.string("-sdk"), .string(sdk.path)]),
        ]))
    }

    @Test
    func sourceKitResponseReadsFullValueSurface() {
        let response = SourceKitResponse(value: [
            "null": .null,
            "bool": true,
            "double": 1.5,
            "data": .data(Data([1, 2, 3])),
            "array": ["value"],
            "dictionary": ["child": 7],
        ])

        #expect(response.dictionaryValue(for: "null") == .null)
        #expect(response.bool(for: "bool") == true)
        #expect(response.double(for: "double") == 1.5)
        #expect(response.data(for: "data") == Data([1, 2, 3]))
        #expect(response.array(for: "array") == [.string("value")])
        #expect(response.dictionary(for: "dictionary") == ["child": .int64(7)])
    }

    @Test
    func sourceKitResponseReturnsNilForWrongShape() {
        let response = SourceKitResponse(value: [
            "string": "value",
        ])

        #expect(response.int64(for: "string") == nil)
        #expect(response.dictionaryValue(for: "missing") == nil)
        #expect(SourceKitResponse(value: "not a dictionary").string(for: "string") == nil)
    }

    @Test
    func sourceKitValueSupportsSwiftLiterals() {
        let value: SourceKitValue = [
            .request: .uid(.compilerVersion),
            "string": "value",
            "int": 1,
            "bool": true,
            "double": 1.25,
            "array": ["child"],
            "dictionary": ["nested": 2],
        ]

        #expect(value == .dictionary([
            .request: .uid(.compilerVersion),
            "string": .string("value"),
            "int": .int64(1),
            "bool": .bool(true),
            "double": .double(1.25),
            "array": .array([.string("child")]),
            "dictionary": .dictionary(["nested": .int64(2)]),
        ]))
    }

    @Test
    func sourceKitValueDictionaryLiteralUsesLastDuplicateKey() {
        let value: SourceKitValue = [
            "key": 1,
            "key": 2,
        ]

        #expect(value == ["key": 2])
    }

    @Test
    func sourceKitValueBuildsRequestDictionary() {
        #expect(SourceKitValue.request(.compilerVersion) == [
            .request: .uid(.compilerVersion),
        ])
    }

    @Test
    func sourceKitUIDProvidesFlatAliasesForCommonKeysAndRequests() {
        #expect(SourceKitUID.request == .Key.request)
        #expect(SourceKitUID.sourceFile == .Key.sourceFile)
        #expect(SourceKitUID.offset == .Key.offset)
        #expect(SourceKitUID.compilerArguments == .Key.compilerArgs)
        #expect(SourceKitUID.name == .Key.name)
        #expect(SourceKitUID.usr == .Key.usr)
        #expect(SourceKitUID.typeName == .Key.typeName)
        #expect(SourceKitUID.declarationFile == .Key.filePath)
        #expect(SourceKitUID.declarationOffset == .Key.offset)
        #expect(SourceKitUID.versionMajor == .Key.versionMajor)
        #expect(SourceKitUID.versionMinor == .Key.versionMinor)
        #expect(SourceKitUID.versionPatch == .Key.versionPatch)
        #expect(SourceKitUID.cursorInfo == .Request.cursorInfo)
        #expect(SourceKitUID.compilerVersion == .Request.compilerVersion)
    }

    @Test
    func sourceKitUIDCoversPinnedUpstreamProtocolSurface() {
        #expect(SourceKitUID.Key.all.count == 208)
        #expect(SourceKitUID.Request.all.count == 55)
        #expect(SourceKitUID.Kind.all.count == 188)

        #expect(SourceKitUID.Key.filePath.rawValue == "key.filepath")
        #expect(SourceKitUID.Key.sourceText.rawValue == "key.sourcetext")
        #expect(SourceKitUID.Key.vfsName.rawValue == "key.vfs.name")
        #expect(SourceKitUID.Request.editorOpen.rawValue == "source.request.editor.open")
        #expect(SourceKitUID.Request.semanticTokens.rawValue == "source.request.semantic_tokens")
        #expect(SourceKitUID.Kind.declFunctionFree.rawValue == "source.lang.swift.decl.function.free")
        #expect(SourceKitUID.Kind.macroRoleExpression.rawValue == "source.lang.swift.macro_role.expression")
    }

    @Test
    func unsafeSwiftInteropIsBoxedInSourceKitDInterop() throws {
        let sourceDirectory = packageRoot().appendingPathComponent("Sources/SwiftSourceKit")
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "swift" }

        let unsafePatterns = [
            "import CSourceKitDShim",
            "OpaquePointer",
            "Unsafe",
            "unsafeBitCast",
            "dlopen",
            "dlsym",
            "swift_sourcekitd_",
            "@convention(c)",
        ]

        for file in files where file.lastPathComponent != "SourceKitDInterop.swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for pattern in unsafePatterns {
                #expect(!contents.contains(pattern), "\(pattern) leaked into \(file.lastPathComponent)")
            }
        }
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

        let value = try await client.send(.request(.compilerVersion))

        guard case .dictionary(let dictionary) = value else {
            Issue.record("Expected dictionary response")
            return
        }
        #expect(dictionary[.versionMajor] != nil)
    }

    @Test
    func clientRejectsDifferentSourceKitDPathAfterInitialization() async throws {
        let client: SourceKitClient
        do {
            client = try SourceKitClient(libraryPath: sourceKitDPath())
        } catch SourceKitError.sourceKitUnavailable {
            return
        }

        _ = try await client.compilerVersion()

        do {
            _ = try SourceKitClient(libraryPath: "/tmp/not-sourcekitd-\(UUID().uuidString)")
            Issue.record("Expected incompatible sourcekitd runtime")
        } catch SourceKitError.incompatibleSourceKitD(let message) {
            #expect(message.contains("already initialized"))
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

private extension String {
    func utf8Offset(of needle: String) -> Int? {
        guard let range = range(of: needle) else {
            return nil
        }
        return utf8.distance(from: utf8.startIndex, to: range.lowerBound.samePosition(in: utf8)!)
    }
}

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
