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
        .dictionary([
            .Key.request: .uid(.Request.cursorInfo),
            .Key.name: .string(location.file.path),
            .Key.sourceFile: .string(location.file.path),
            .Key.offset: .int64(location.byteOffset),
            .Key.compilerArguments: .array(context.compilerArguments.map(SourceKitValue.string)),
        ])
    }

    public func decode(from response: SourceKitResponse) throws -> CursorInfo {
        CursorInfo(
            name: response.string(for: .Key.name),
            usr: response.string(for: .Key.usr),
            typeName: response.string(for: .Key.typeName),
            declarationFile: response.string(for: .Key.declarationFile),
            declarationOffset: response.int64(for: .Key.declarationOffset)
        )
    }
}
