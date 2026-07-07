import Foundation

public struct CursorInfo: Equatable, Sendable {
    public let name: String?
    public let usr: String?
    public let typeName: String?
    public let declarationFile: String?
    public let declarationOffset: Int64?

    public init(
        name: String?,
        usr: String?,
        typeName: String?,
        declarationFile: String?,
        declarationOffset: Int64?
    ) {
        self.name = name
        self.usr = usr
        self.typeName = typeName
        self.declarationFile = declarationFile
        self.declarationOffset = declarationOffset
    }
}

public struct CursorInfoRequest: SourceKitRequest {
    public typealias Response = CursorInfo

    public let location: SourceKitLocation
    public let context: SourceKitBuildContext

    public init(location: SourceKitLocation, context: SourceKitBuildContext) {
        self.location = location
        self.context = context
    }

    public var value: SourceKitValue {
        [
            .request: .uid(.cursorInfo),
            .name: .string(location.file.path),
            .sourceFile: .string(location.file.path),
            .offset: .int64(location.byteOffset),
            .compilerArguments: .array(context.compilerArguments.map(SourceKitValue.string)),
        ]
    }

    public func decode(from response: SourceKitResponse) throws -> CursorInfo {
        CursorInfo(
            name: response.string(for: .name),
            usr: response.string(for: .usr),
            typeName: response.string(for: .typeName),
            declarationFile: response.string(for: .declarationFile),
            declarationOffset: response.int64(for: .declarationOffset)
        )
    }
}
