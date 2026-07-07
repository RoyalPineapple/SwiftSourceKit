import Foundation

public actor SourceKitClient {
    private let runtime: SourceKitDRuntime

    public init(libraryPath: String? = nil) throws {
        self.runtime = try SourceKitDRuntime(libraryPath: libraryPath)
    }

    public func send(_ request: SourceKitValue) async throws -> SourceKitValue {
        try await runtime.send(request)
    }

    public func send<Request: SourceKitRequest>(
        _ request: Request
    ) async throws -> Request.Response {
        try request.decode(from: SourceKitResponse(value: try await send(request.value)))
    }

    public func cursorInfo(
        at location: SourceKitLocation,
        context: SourceKitBuildContext
    ) async throws -> CursorInfo {
        try await send(CursorInfoRequest(location: location, context: context))
    }

    public func compilerVersion() async throws -> CompilerVersion {
        try await send(CompilerVersionRequest())
    }
}
