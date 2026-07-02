import Foundation

public actor SourceKitClient {
    private let bridge: SourceKitD

    public init(libraryPath: String? = nil) throws {
        self.bridge = try SourceKitD(libraryPath: libraryPath)
    }

    public func send(_ request: SourceKitValue) async throws -> SourceKitValue {
        try bridge.send(request)
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
