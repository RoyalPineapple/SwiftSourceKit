public struct CompilerVersion: Equatable, Sendable {
    public let major: Int64?
    public let minor: Int64?
    public let patch: Int64?

    public init(major: Int64?, minor: Int64?, patch: Int64?) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public struct CompilerVersionRequest: SourceKitRequest {
    public typealias Response = CompilerVersion

    public init() {}

    public var value: SourceKitValue {
        .request(.compilerVersion)
    }

    public func decode(from response: SourceKitResponse) throws -> CompilerVersion {
        CompilerVersion(
            major: response.int64(for: .versionMajor),
            minor: response.int64(for: .versionMinor),
            patch: response.int64(for: .versionPatch)
        )
    }
}
