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
