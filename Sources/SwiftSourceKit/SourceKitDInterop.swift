import Darwin
import Foundation
import Synchronization
import CSourceKitDShim

private typealias SKObject = OpaquePointer
private typealias SKResponse = OpaquePointer
private typealias SKUID = OpaquePointer
private typealias SKVariant = SwiftSourceKitDVariant
private typealias SKRequestHandle = UnsafeRawPointer
private typealias SKResponseReceiver = @convention(block) (SKResponse) -> Void

final class SourceKitDRuntime: @unchecked Sendable {
    private let functions: SourceKitDFunctions

    init(libraryPath: String?) throws {
        let path = libraryPath ?? Self.defaultLibraryPath()
        self.functions = try Self.loadRuntimeFunctions(from: path)
    }

    func send(_ value: SourceKitValue) async throws -> SourceKitValue {
        let request = try SourceKitRequestEncoder(functions: functions).encode(value)
        let operation = AsyncSourceKitRequest(functions: functions)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request: request, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private static let runtimeState = Mutex<InitializedSourceKitDRuntime?>(nil)

    private static func loadRuntimeFunctions(from path: String) throws -> SourceKitDFunctions {
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
                let functions = try SourceKitDFunctions(handle: handle)
                try validateShimABI()
                functions.initialize()
                runtime = InitializedSourceKitDRuntime(path: canonicalPath, handle: handle, functions: functions)
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
}

private struct InitializedSourceKitDRuntime: @unchecked Sendable {
    let path: String
    let handle: UnsafeMutableRawPointer
    let functions: SourceKitDFunctions
}

private final class ManagedSourceKitRequest: @unchecked Sendable {
    let raw: SKObject
    private let functions: SourceKitDFunctions

    init(raw: SKObject, functions: SourceKitDFunctions) {
        self.raw = raw
        self.functions = functions
    }

    deinit {
        functions.requestRelease(raw)
    }
}

private final class ManagedSourceKitRequestHandle: @unchecked Sendable {
    private let raw: SKRequestHandle
    private let functions: SourceKitDFunctions

    init(raw: SKRequestHandle, functions: SourceKitDFunctions) {
        self.raw = raw
        self.functions = functions
    }

    func cancel() {
        functions.cancelRequest(raw)
    }

    deinit {
        functions.requestHandleDispose(raw)
    }
}

private final class AsyncSourceKitRequest: @unchecked Sendable {
    private struct State: Sendable {
        var request: ManagedSourceKitRequest?
        var handle: ManagedSourceKitRequestHandle?
        var continuation: CheckedContinuation<SourceKitValue, Error>?
        var isComplete = false
        var cancelWhenStarted = false
    }

    private let functions: SourceKitDFunctions
    private let state = Mutex(State())

    init(functions: SourceKitDFunctions) {
        self.functions = functions
    }

    func start(
        request: ManagedSourceKitRequest,
        continuation: CheckedContinuation<SourceKitValue, Error>
    ) {
        let isCancelled = state.withLock { state in
            state.request = request
            state.continuation = continuation
            return state.cancelWhenStarted
        }
        guard !isCancelled else {
            complete(.failure(CancellationError()))
            return
        }

        var rawHandle: SKRequestHandle?
        let receiver: SKResponseReceiver = { [self] response in
            self.receive(response)
        }
        functions.sendRequest(request.raw, &rawHandle, receiver)

        guard let rawHandle else {
            complete(.failure(SourceKitError.requestFailed(kind: -1, description: "sourcekitd returned no request handle")))
            return
        }

        let handle = ManagedSourceKitRequestHandle(raw: rawHandle, functions: functions)
        let shouldCancel = state.withLock { state in
            guard !state.isComplete else {
                return true
            }
            state.handle = handle
            return state.cancelWhenStarted
        }

        if shouldCancel {
            handle.cancel()
            complete(.failure(CancellationError()))
        }
    }

    func cancel() {
        let (handle, continuation) = state.withLock { state in
            guard !state.isComplete else {
                return (
                    nil as ManagedSourceKitRequestHandle?,
                    nil as CheckedContinuation<SourceKitValue, Error>?
                )
            }
            state.cancelWhenStarted = true
            guard let continuation = state.continuation else {
                return (state.handle, nil)
            }

            let handle = state.handle
            state.isComplete = true
            state.request = nil
            state.handle = nil
            state.continuation = nil
            return (handle, continuation)
        }
        handle?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func receive(_ response: SKResponse) {
        let result: Result<SourceKitValue, Error>
        do {
            result = .success(try process(response: response))
        } catch {
            result = .failure(error)
        }
        complete(result)
    }

    private func process(response: SKResponse) throws -> SourceKitValue {
        defer {
            functions.responseDispose(response)
        }

        if functions.responseIsError(response) != 0 {
            let kind = functions.responseErrorGetKind(response)
            let description = functions.responseErrorGetDescription(response)
                .map { String(cString: $0) } ?? "unknown sourcekitd error"
            throw SourceKitError.requestFailed(kind: kind, description: description)
        }

        return try SourceKitResponseDecoder(functions: functions)
            .decode(functions.responseGetValue(response))
    }

    private func complete(_ result: Result<SourceKitValue, Error>) {
        let continuation = state.withLock { state in
            guard !state.isComplete else {
                return nil as CheckedContinuation<SourceKitValue, Error>?
            }
            state.isComplete = true
            state.request = nil
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }

        continuation?.resume(with: result)
    }
}

private struct SourceKitRequestEncoder {
    let functions: SourceKitDFunctions

    func encode(_ value: SourceKitValue) throws -> ManagedSourceKitRequest {
        try ManagedSourceKitRequest(raw: makeObject(from: value), functions: functions)
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
                        let child = try encode(value)
                        functions.requestDictionarySetValue(object, uid, child.raw)
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
                        let child = try encode(value)
                        functions.requestArraySetValue(object, .arrayAppendIndex, child.raw)
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
}

private extension Int {
    static let arrayAppendIndex = -1
}

private struct SourceKitResponseDecoder {
    let functions: SourceKitDFunctions

    func decode(_ variant: SKVariant) throws -> SourceKitValue {
        switch VariantType(rawValue: functions.variantGetType(variant)) {
        case .dictionary:
            return try decodeDictionary(variant)
        case .array:
            return try decodeArray(variant)
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

    private func decodeDictionary(_ variant: SKVariant) throws -> SourceKitValue {
        let box = VariantDictionaryBox(decoder: self)
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

    private func decodeArray(_ variant: SKVariant) throws -> SourceKitValue {
        let count = functions.variantArrayGetCount(variant)
        let values = try (0..<count).map { index in
            try decode(functions.variantArrayGetValue(variant, index))
        }
        return .array(values)
    }
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
    let decoder: SourceKitResponseDecoder
    var values: [SourceKitUID: SourceKitValue] = [:]
    var error: SourceKitError?

    init(decoder: SourceKitResponseDecoder) {
        self.decoder = decoder
    }

    func insert(key: SKUID, variant: SKVariant) -> Bool {
        do {
            let sourceKitKey = SourceKitUID(rawValue: decoder.functions.uidString(key))
            values[sourceKitKey] = try decoder.decode(variant)
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

private struct SourceKitDFunctions: @unchecked Sendable {
    let initialize: @convention(c) () -> Void
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
    let sendRequest: @convention(c) (SKObject, UnsafeMutablePointer<SKRequestHandle?>?, SKResponseReceiver) -> Void
    let cancelRequest: @convention(c) (SKRequestHandle) -> Void
    let requestHandleDispose: @convention(c) (SKRequestHandle) -> Void
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
    let variantDictionaryApplyPointer: UnsafeMutableRawPointer
    let variantArrayGetCountPointer: UnsafeMutableRawPointer
    let variantArrayGetValuePointer: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) throws {
        initialize = try Self.load(handle, "sourcekitd_initialize")
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
        sendRequest = try Self.load(handle, "sourcekitd_send_request")
        cancelRequest = try Self.load(handle, "sourcekitd_cancel_request")
        requestHandleDispose = try Self.load(handle, "sourcekitd_request_handle_dispose")
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
