public extension SourceKitUID {
    enum Key {
        public static let request: SourceKitUID = "key.request"
        public static let sourceFile: SourceKitUID = "key.sourcefile"
        public static let offset: SourceKitUID = "key.offset"
        public static let compilerArguments: SourceKitUID = "key.compilerargs"
        public static let name: SourceKitUID = "key.name"
        public static let usr: SourceKitUID = "key.usr"
        public static let typeName: SourceKitUID = "key.typename"
        public static let declarationFile: SourceKitUID = "key.filepath"
        public static let declarationOffset: SourceKitUID = "key.offset"
        public static let versionMajor: SourceKitUID = "key.version_major"
        public static let versionMinor: SourceKitUID = "key.version_minor"
        public static let versionPatch: SourceKitUID = "key.version_patch"
    }

    enum Request {
        public static let cursorInfo: SourceKitUID = "source.request.cursorinfo"
        public static let compilerVersion: SourceKitUID = "source.request.compiler_version"
    }
}
