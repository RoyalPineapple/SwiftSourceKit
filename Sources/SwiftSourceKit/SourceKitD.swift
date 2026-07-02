import Darwin
import Foundation
import Synchronization
import CSourceKitDShim

typealias SKObject = OpaquePointer
typealias SKResponse = OpaquePointer
typealias SKUID = OpaquePointer
typealias SKVariant = SwiftSourceKitDVariant

final class SourceKitD: @unchecked Sendable {
    private let functions: Functions

    init(libraryPath: String?) throws {
        let path = libraryPath ?? Self.defaultLibraryPath()
        self.functions = try Self.loadRuntimeFunctions(from: path)
    }

    func send(_ value: SourceKitValue) throws -> SourceKitValue {
        let request = try makeObject(from: value)
        defer { functions.requestRelease(request) }

        guard let response = functions.sendRequestSync(request) else {
            throw SourceKitError.requestFailed(kind: -1, description: "sourcekitd returned no response")
        }
        defer { functions.responseDispose(response) }

        if functions.responseIsError(response) != 0 {
            let kind = functions.responseErrorGetKind(response)
            let description = functions.responseErrorGetDescription(response)
                .map { String(cString: $0) } ?? "unknown sourcekitd error"
            throw SourceKitError.requestFailed(kind: kind, description: description)
        }

        let variant = functions.responseGetValue(response)
        return try Self.decode(variant, functions: functions)
    }

    private func makeObject(from value: SourceKitValue) throws -> SKObject {
        switch value {
        case .dictionary(let dictionary):
            let object = functions.requestDictionaryCreate(nil, nil, 0)
            do {
                for (key, value) in dictionary {
                    let uid = functions.uid(key.rawValue)
                    switch value {
                    case .string(let string):
                        functions.requestDictionarySetString(object, uid, string)
                    case .int64(let int):
                        functions.requestDictionarySetInt64(object, uid, int)
                    case .uid(let uidValue):
                        functions.requestDictionarySetUID(object, uid, functions.uid(uidValue.rawValue))
                    case .array, .dictionary:
                        let child = try makeObject(from: value)
                        functions.requestDictionarySetValue(object, uid, child)
                        // SourceKit's XPC path retains and in-process path stores ref-counted values.
                        functions.requestRelease(child)
                    case .null, .bool, .double, .data:
                        throw unsupportedRequestValue(value)
                    }
                }
                return object
            } catch {
                functions.requestRelease(object)
                throw error
            }

        case .array(let array):
            let object = functions.requestArrayCreate(nil, 0)
            do {
                for value in array {
                    switch value {
                    case .string(let string):
                        functions.requestArraySetString(object, .arrayAppendIndex, string)
                    case .int64(let int):
                        functions.requestArraySetInt64(object, .arrayAppendIndex, int)
                    case .uid(let uidValue):
                        functions.requestArraySetUID(object, .arrayAppendIndex, functions.uid(uidValue.rawValue))
                    case .array, .dictionary:
                        let child = try makeObject(from: value)
                        functions.requestArraySetValue(object, .arrayAppendIndex, child)
                        // SourceKit's XPC path retains and in-process path stores ref-counted values.
                        functions.requestRelease(child)
                    case .null, .bool, .double, .data:
                        throw unsupportedRequestValue(value)
                    }
                }
                return object
            } catch {
                functions.requestRelease(object)
                throw error
            }

        case .null, .bool, .double, .data:
            throw unsupportedRequestValue(value)
        case .string(let string):
            return functions.requestStringCreate(string)
        case .int64(let int):
            return functions.requestInt64Create(int)
        case .uid(let uid):
            return functions.requestUIDCreate(functions.uid(uid.rawValue))
        }
    }

    private func unsupportedRequestValue(_ value: SourceKitValue) -> SourceKitError {
        SourceKitError.invalidRequest("sourcekitd.h exposes no request constructor/setter for \(value)")
    }

    fileprivate static func decode(_ variant: SKVariant, functions: Functions) throws -> SourceKitValue {
        switch VariantType(rawValue: functions.variantGetType(variant)) {
        case .dictionary:
            return try decodeDictionary(variant, functions: functions)
        case .array:
            return try decodeArray(variant, functions: functions)
        case .int64:
            return .int64(functions.variantInt64GetValue(variant))
        case .string:
            return .string(functions.variantStringGetPointer(variant).map { String(cString: $0) } ?? "")
        case .uid:
            return .uid(SourceKitUID(rawValue: functions.uidString(functions.variantUIDGetValue(variant))))
        case .bool:
            return .bool(functions.variantBoolGetValue(variant))
        case .double:
            return .double(functions.variantDoubleGetValue(variant))
        case .data:
            guard let pointer = functions.variantDataGetPointer(variant) else {
                return .data(Data())
            }
            return .data(Data(bytes: pointer, count: functions.variantDataGetSize(variant)))
        case .null:
            return .null
        case .none:
            throw SourceKitError.responseDecodeFailed("unsupported sourcekitd variant type \(functions.variantGetType(variant))")
        }
    }

    private static func decodeDictionary(_ variant: SKVariant, functions: Functions) throws -> SourceKitValue {
        let box = VariantDictionaryBox(functions: functions)
        var dictionary = variant
        let context = Unmanaged.passUnretained(box).toOpaque()
        _ = swift_sourcekitd_variant_dictionary_apply(
            functions.variantDictionaryApplyPointer,
            &dictionary,
            sourceKitDVariantDictionaryApplier,
            context
        )
        if let error = box.error {
            throw error
        }
        return .dictionary(box.values)
    }

    private static func decodeArray(_ variant: SKVariant, functions: Functions) throws -> SourceKitValue {
        let count = functions.variantArrayGetCount(variant)
        let values = try (0..<count).map { index in
            try decode(functions.variantArrayGetValue(variant, index), functions: functions)
        }
        return .array(values)
    }

    private static func defaultLibraryPath() -> String {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? xcodeSelectDeveloperDirectory()
            ?? "/Applications/Xcode.app/Contents/Developer"
        return developerDirectory + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/sourcekitd"
    }

    private static func xcodeSelectDeveloperDirectory() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static let runtimeState = Mutex<InitializedRuntime?>(nil)

    private static func loadRuntimeFunctions(from path: String) throws -> Functions {
        let canonicalPath = canonicalLibraryPath(path)
        return try runtimeState.withLock { runtime in
            if let runtime {
                guard runtime.path == canonicalPath else {
                    throw SourceKitError.incompatibleSourceKitD(
                        "sourcekitd is already initialized from \(runtime.path); refusing to load \(canonicalPath) in the same process"
                    )
                }
                return runtime.functions
            }

            guard let handle = dlopen(canonicalPath, RTLD_NOW | RTLD_LOCAL) else {
                let message = dlerror().map { String(cString: $0) } ?? canonicalPath
                throw SourceKitError.sourceKitUnavailable(message)
            }

            do {
                let functions = try Functions(handle: handle)
                try validateShimABI()
                functions.initialize()
                do {
                    try validateLoadedRuntime(functions)
                } catch {
                    functions.shutdown()
                    throw error
                }
                runtime = InitializedRuntime(path: canonicalPath, handle: handle, functions: functions)
                return functions
            } catch {
                dlclose(handle)
                throw error
            }
        }
    }

    private static func canonicalLibraryPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func resetForTesting() {
        runtimeState.withLock { runtime in
            guard let loaded = runtime else {
                return
            }

            loaded.functions.shutdown()
            dlclose(loaded.handle)
            runtime = nil
        }
    }

    private static func validateShimABI() throws {
        let expectedVariantSize = 3 * MemoryLayout<UInt64>.size
        guard MemoryLayout<SKVariant>.size == expectedVariantSize else {
            throw SourceKitError.incompatibleSourceKitD(
                "SwiftSourceKitDVariant is \(MemoryLayout<SKVariant>.size) bytes, expected \(expectedVariantSize)"
            )
        }

        guard MemoryLayout<SKVariant>.alignment == MemoryLayout<UInt64>.alignment else {
            throw SourceKitError.incompatibleSourceKitD(
                "SwiftSourceKitDVariant alignment is \(MemoryLayout<SKVariant>.alignment), expected \(MemoryLayout<UInt64>.alignment)"
            )
        }

        let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
        guard MemoryLayout<SKObject>.size == pointerSize,
              MemoryLayout<SKResponse>.size == pointerSize,
              MemoryLayout<SKUID>.size == pointerSize else {
            throw SourceKitError.incompatibleSourceKitD("sourcekitd opaque handles do not match pointer size")
        }
    }

    private static func validateLoadedRuntime(_ functions: Functions) throws {
        let request = functions.requestDictionaryCreate(nil, nil, 0)
        defer { functions.requestRelease(request) }

        functions.requestDictionarySetUID(
            request,
            functions.uid(SourceKitUID.Key.request.rawValue),
            functions.uid(SourceKitUID.Request.compilerVersion.rawValue)
        )

        guard let response = functions.sendRequestSync(request) else {
            throw SourceKitError.incompatibleSourceKitD("compatibility probe returned no response")
        }
        defer { functions.responseDispose(response) }

        if functions.responseIsError(response) != 0 {
            let kind = functions.responseErrorGetKind(response)
            let description = functions.responseErrorGetDescription(response)
                .map { String(cString: $0) } ?? "unknown sourcekitd error"
            throw SourceKitError.incompatibleSourceKitD("compatibility probe failed (\(kind)): \(description)")
        }

        let variant = functions.responseGetValue(response)
        guard functions.variantGetType(variant) == VariantType.dictionary.rawValue else {
            throw SourceKitError.incompatibleSourceKitD("compatibility probe did not return a dictionary response")
        }

        let decoded: SourceKitValue
        do {
            decoded = try decode(variant, functions: functions)
        } catch {
            throw SourceKitError.incompatibleSourceKitD("compatibility probe response could not be decoded: \(error)")
        }

        guard case .dictionary(let dictionary) = decoded,
              case .int64 = dictionary[.Key.versionMajor] else {
            throw SourceKitError.incompatibleSourceKitD("compatibility probe response did not include key.version_major")
        }
    }
}

private struct InitializedRuntime: @unchecked Sendable {
    let path: String
    // Keep the dlopen handle alive because sourcekitd initialization is process-global.
    let handle: UnsafeMutableRawPointer
    let functions: SourceKitD.Functions
}

private extension Int {
    static let arrayAppendIndex = -1
}

private enum VariantType: Int32 {
    case null = 0
    case dictionary = 1
    case array = 2
    case int64 = 3
    case string = 4
    case uid = 5
    case bool = 6
    case double = 7
    case data = 8
}

private final class VariantDictionaryBox: @unchecked Sendable {
    let functions: SourceKitD.Functions
    var values: [SourceKitUID: SourceKitValue] = [:]
    var error: SourceKitError?

    init(functions: SourceKitD.Functions) {
        self.functions = functions
    }

    func insert(key: SKUID, variant: SKVariant) -> Bool {
        do {
            let sourceKitKey = SourceKitUID(rawValue: functions.uidString(key))
            values[sourceKitKey] = try SourceKitD.decode(variant, functions: functions)
            return true
        } catch let sourceKitError as SourceKitError {
            error = sourceKitError
            return false
        } catch let decodingError {
            error = .responseDecodeFailed(String(describing: decodingError))
            return false
        }
    }
}

private let sourceKitDVariantDictionaryApplier:
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<SKVariant>?, UnsafeMutableRawPointer?) -> Bool = { key, value, context in
        guard let key, let value, let context else {
            return false
        }

        let box = Unmanaged<VariantDictionaryBox>.fromOpaque(context).takeUnretainedValue()
        return box.insert(key: OpaquePointer(key), variant: value.pointee)
    }

extension SourceKitD {
    struct Functions: @unchecked Sendable {
        let initialize: @convention(c) () -> Void
        let shutdown: @convention(c) () -> Void
        let uidGetFromCString: @convention(c) (UnsafePointer<CChar>) -> SKUID
        let uidGetStringPointer: @convention(c) (SKUID) -> UnsafePointer<CChar>
        let requestDictionaryCreate: @convention(c) (UnsafePointer<SKUID?>?, UnsafePointer<SKObject?>?, Int) -> SKObject
        let requestDictionarySetString: @convention(c) (SKObject, SKUID, UnsafePointer<CChar>) -> Void
        let requestDictionarySetInt64: @convention(c) (SKObject, SKUID, Int64) -> Void
        let requestDictionarySetUID: @convention(c) (SKObject, SKUID, SKUID) -> Void
        let requestDictionarySetValue: @convention(c) (SKObject, SKUID, SKObject) -> Void
        let requestArrayCreate: @convention(c) (UnsafePointer<SKObject?>?, Int) -> SKObject
        let requestArraySetString: @convention(c) (SKObject, Int, UnsafePointer<CChar>) -> Void
        let requestArraySetInt64: @convention(c) (SKObject, Int, Int64) -> Void
        let requestArraySetUID: @convention(c) (SKObject, Int, SKUID) -> Void
        let requestArraySetValue: @convention(c) (SKObject, Int, SKObject) -> Void
        let requestStringCreate: @convention(c) (UnsafePointer<CChar>) -> SKObject
        let requestInt64Create: @convention(c) (Int64) -> SKObject
        let requestUIDCreate: @convention(c) (SKUID) -> SKObject
        let requestRelease: @convention(c) (SKObject) -> Void
        let sendRequestSync: @convention(c) (SKObject) -> SKResponse?
        let responseDispose: @convention(c) (SKResponse) -> Void
        let responseIsError: @convention(c) (SKResponse) -> Int32
        let responseErrorGetKind: @convention(c) (SKResponse) -> Int64
        let responseErrorGetDescription: @convention(c) (SKResponse) -> UnsafePointer<CChar>?
        let responseGetValuePointer: UnsafeMutableRawPointer
        let variantGetTypePointer: UnsafeMutableRawPointer
        let variantInt64GetValuePointer: UnsafeMutableRawPointer
        let variantBoolGetValuePointer: UnsafeMutableRawPointer
        let variantDoubleGetValuePointer: UnsafeMutableRawPointer
        let variantStringGetPointerPointer: UnsafeMutableRawPointer
        let variantDataGetSizePointer: UnsafeMutableRawPointer
        let variantDataGetPointerPointer: UnsafeMutableRawPointer
        let variantUIDGetValuePointer: UnsafeMutableRawPointer
        let variantDictionaryGetValuePointer: UnsafeMutableRawPointer
        let variantDictionaryGetStringPointer: UnsafeMutableRawPointer
        let variantDictionaryGetInt64Pointer: UnsafeMutableRawPointer
        let variantDictionaryGetUIDPointer: UnsafeMutableRawPointer
        let variantDictionaryApplyPointer: UnsafeMutableRawPointer
        let variantArrayGetCountPointer: UnsafeMutableRawPointer
        let variantArrayGetValuePointer: UnsafeMutableRawPointer

        init(handle: UnsafeMutableRawPointer) throws {
            initialize = try Self.load(handle, "sourcekitd_initialize")
            shutdown = try Self.load(handle, "sourcekitd_shutdown")
            uidGetFromCString = try Self.load(handle, "sourcekitd_uid_get_from_cstr")
            uidGetStringPointer = try Self.load(handle, "sourcekitd_uid_get_string_ptr")
            requestDictionaryCreate = try Self.load(handle, "sourcekitd_request_dictionary_create")
            requestDictionarySetString = try Self.load(handle, "sourcekitd_request_dictionary_set_string")
            requestDictionarySetInt64 = try Self.load(handle, "sourcekitd_request_dictionary_set_int64")
            requestDictionarySetUID = try Self.load(handle, "sourcekitd_request_dictionary_set_uid")
            requestDictionarySetValue = try Self.load(handle, "sourcekitd_request_dictionary_set_value")
            requestArrayCreate = try Self.load(handle, "sourcekitd_request_array_create")
            requestArraySetString = try Self.load(handle, "sourcekitd_request_array_set_string")
            requestArraySetInt64 = try Self.load(handle, "sourcekitd_request_array_set_int64")
            requestArraySetUID = try Self.load(handle, "sourcekitd_request_array_set_uid")
            requestArraySetValue = try Self.load(handle, "sourcekitd_request_array_set_value")
            requestStringCreate = try Self.load(handle, "sourcekitd_request_string_create")
            requestInt64Create = try Self.load(handle, "sourcekitd_request_int64_create")
            requestUIDCreate = try Self.load(handle, "sourcekitd_request_uid_create")
            requestRelease = try Self.load(handle, "sourcekitd_request_release")
            sendRequestSync = try Self.load(handle, "sourcekitd_send_request_sync")
            responseDispose = try Self.load(handle, "sourcekitd_response_dispose")
            responseIsError = try Self.load(handle, "sourcekitd_response_is_error")
            responseErrorGetKind = try Self.load(handle, "sourcekitd_response_error_get_kind")
            responseErrorGetDescription = try Self.load(handle, "sourcekitd_response_error_get_description")
            responseGetValuePointer = try Self.loadPointer(handle, "sourcekitd_response_get_value")
            variantGetTypePointer = try Self.loadPointer(handle, "sourcekitd_variant_get_type")
            variantInt64GetValuePointer = try Self.loadPointer(handle, "sourcekitd_variant_int64_get_value")
            variantBoolGetValuePointer = try Self.loadPointer(handle, "sourcekitd_variant_bool_get_value")
            variantDoubleGetValuePointer = try Self.loadPointer(handle, "sourcekitd_variant_double_get_value")
            variantStringGetPointerPointer = try Self.loadPointer(handle, "sourcekitd_variant_string_get_ptr")
            variantDataGetSizePointer = try Self.loadPointer(handle, "sourcekitd_variant_data_get_size")
            variantDataGetPointerPointer = try Self.loadPointer(handle, "sourcekitd_variant_data_get_ptr")
            variantUIDGetValuePointer = try Self.loadPointer(handle, "sourcekitd_variant_uid_get_value")
            variantDictionaryGetValuePointer = try Self.loadPointer(handle, "sourcekitd_variant_dictionary_get_value")
            variantDictionaryGetStringPointer = try Self.loadPointer(handle, "sourcekitd_variant_dictionary_get_string")
            variantDictionaryGetInt64Pointer = try Self.loadPointer(handle, "sourcekitd_variant_dictionary_get_int64")
            variantDictionaryGetUIDPointer = try Self.loadPointer(handle, "sourcekitd_variant_dictionary_get_uid")
            variantDictionaryApplyPointer = try Self.loadPointer(handle, "sourcekitd_variant_dictionary_apply_f")
            variantArrayGetCountPointer = try Self.loadPointer(handle, "sourcekitd_variant_array_get_count")
            variantArrayGetValuePointer = try Self.loadPointer(handle, "sourcekitd_variant_array_get_value")
        }

        func uid(_ string: String) -> SKUID {
            string.withCString { uidGetFromCString($0) }
        }

        func uidString(_ uid: SKUID) -> String {
            String(cString: uidGetStringPointer(uid))
        }

        func responseGetValue(_ response: SKResponse) -> SKVariant {
            var value = SKVariant()
            swift_sourcekitd_response_get_value(responseGetValuePointer, UnsafeMutableRawPointer(response), &value)
            return value
        }

        func variantGetType(_ variant: SKVariant) -> Int32 {
            var value = variant
            return swift_sourcekitd_variant_get_type(variantGetTypePointer, &value)
        }

        func variantInt64GetValue(_ variant: SKVariant) -> Int64 {
            var value = variant
            return swift_sourcekitd_variant_int64_get_value(variantInt64GetValuePointer, &value)
        }

        func variantBoolGetValue(_ variant: SKVariant) -> Bool {
            var value = variant
            return swift_sourcekitd_variant_bool_get_value(variantBoolGetValuePointer, &value)
        }

        func variantDoubleGetValue(_ variant: SKVariant) -> Double {
            var value = variant
            return swift_sourcekitd_variant_double_get_value(variantDoubleGetValuePointer, &value)
        }

        func variantStringGetPointer(_ variant: SKVariant) -> UnsafePointer<CChar>? {
            var value = variant
            return swift_sourcekitd_variant_string_get_ptr(variantStringGetPointerPointer, &value)
        }

        func variantDataGetSize(_ variant: SKVariant) -> Int {
            var value = variant
            return swift_sourcekitd_variant_data_get_size(variantDataGetSizePointer, &value)
        }

        func variantDataGetPointer(_ variant: SKVariant) -> UnsafeRawPointer? {
            var value = variant
            return swift_sourcekitd_variant_data_get_ptr(variantDataGetPointerPointer, &value)
        }

        func variantUIDGetValue(_ variant: SKVariant) -> SKUID {
            var value = variant
            return OpaquePointer(swift_sourcekitd_variant_uid_get_value(variantUIDGetValuePointer, &value))
        }

        func variantArrayGetCount(_ variant: SKVariant) -> Int {
            var value = variant
            return swift_sourcekitd_variant_array_get_count(variantArrayGetCountPointer, &value)
        }

        func variantArrayGetValue(_ array: SKVariant, _ index: Int) -> SKVariant {
            var array = array
            var value = SKVariant()
            swift_sourcekitd_variant_array_get_value(variantArrayGetValuePointer, &array, index, &value)
            return value
        }

        func variantDictionaryGetValue(_ dictionary: SKVariant, _ key: SKUID) -> SKVariant {
            var dictionary = dictionary
            var value = SKVariant()
            swift_sourcekitd_variant_dictionary_get_value(
                variantDictionaryGetValuePointer,
                &dictionary,
                UnsafeMutableRawPointer(key),
                &value
            )
            return value
        }

        func variantDictionaryGetString(_ dictionary: SKVariant, _ key: SKUID) -> UnsafePointer<CChar>? {
            var dictionary = dictionary
            return swift_sourcekitd_variant_dictionary_get_string(
                variantDictionaryGetStringPointer,
                &dictionary,
                UnsafeMutableRawPointer(key)
            )
        }

        func variantDictionaryGetInt64(_ dictionary: SKVariant, _ key: SKUID) -> Int64 {
            var dictionary = dictionary
            return swift_sourcekitd_variant_dictionary_get_int64(
                variantDictionaryGetInt64Pointer,
                &dictionary,
                UnsafeMutableRawPointer(key)
            )
        }

        func variantDictionaryGetUID(_ dictionary: SKVariant, _ key: SKUID) -> SKUID? {
            var dictionary = dictionary
            return swift_sourcekitd_variant_dictionary_get_uid(
                variantDictionaryGetUIDPointer,
                &dictionary,
                UnsafeMutableRawPointer(key)
            ).map { OpaquePointer($0) }
        }

        func requestDictionarySetString(_ object: SKObject, _ key: SKUID, _ string: String) {
            string.withCString { requestDictionarySetString(object, key, $0) }
        }

        func requestArraySetString(_ object: SKObject, _ index: Int, _ string: String) {
            string.withCString { requestArraySetString(object, index, $0) }
        }

        func requestStringCreate(_ string: String) -> SKObject {
            string.withCString { requestStringCreate($0) }
        }

        private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
            guard let symbol = dlsym(handle, name) else {
                throw SourceKitError.missingSymbol(name)
            }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func loadPointer(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> UnsafeMutableRawPointer {
            guard let symbol = dlsym(handle, name) else {
                throw SourceKitError.missingSymbol(name)
            }
            return symbol
        }
    }
}
