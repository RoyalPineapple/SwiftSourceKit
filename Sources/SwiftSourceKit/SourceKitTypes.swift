import Foundation

public struct SourceKitUID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public enum SourceKitValue: Equatable, Sendable {
    case null
    case dictionary([SourceKitUID: SourceKitValue])
    case array([SourceKitValue])
    case string(String)
    case int64(Int64)
    case uid(SourceKitUID)
    case bool(Bool)
    case double(Double)
    case data(Data)
}

extension SourceKitValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (SourceKitUID, SourceKitValue)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
}

extension SourceKitValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: SourceKitValue...) {
        self = .array(elements)
    }
}

extension SourceKitValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension SourceKitValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int64(value)
    }
}

extension SourceKitValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension SourceKitValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

public extension SourceKitValue {
    static func request(_ request: SourceKitUID) -> SourceKitValue {
        [.request: .uid(request)]
    }
}

public struct SourceKitBuildContext: Equatable, Sendable {
    public let compilerArguments: [String]

    public init(compilerArguments: [String]) {
        self.compilerArguments = compilerArguments
    }
}

public struct SourceKitLocation: Equatable, Sendable {
    public let file: URL
    public let byteOffset: Int64

    public init(file: URL, byteOffset: Int64) {
        self.file = file
        self.byteOffset = byteOffset
    }
}

public protocol SourceKitRequest: Sendable {
    associatedtype Response: Sendable

    var value: SourceKitValue { get }

    func decode(from response: SourceKitResponse) throws -> Response
}

public struct SourceKitResponse: Sendable {
    public let value: SourceKitValue

    public init(value: SourceKitValue) {
        self.value = value
    }

    public func string(for key: SourceKitUID) -> String? {
        dictionaryValue(for: key).flatMap {
            if case .string(let value) = $0 { value } else { nil }
        }
    }

    public func int64(for key: SourceKitUID) -> Int64? {
        dictionaryValue(for: key).flatMap {
            if case .int64(let value) = $0 { value } else { nil }
        }
    }

    public func uid(for key: SourceKitUID) -> SourceKitUID? {
        dictionaryValue(for: key).flatMap {
            if case .uid(let value) = $0 { value } else { nil }
        }
    }

    public func bool(for key: SourceKitUID) -> Bool? {
        dictionaryValue(for: key).flatMap {
            if case .bool(let value) = $0 { value } else { nil }
        }
    }

    public func double(for key: SourceKitUID) -> Double? {
        dictionaryValue(for: key).flatMap {
            if case .double(let value) = $0 { value } else { nil }
        }
    }

    public func data(for key: SourceKitUID) -> Data? {
        dictionaryValue(for: key).flatMap {
            if case .data(let value) = $0 { value } else { nil }
        }
    }

    public func dictionary(for key: SourceKitUID) -> [SourceKitUID: SourceKitValue]? {
        dictionaryValue(for: key).flatMap {
            if case .dictionary(let value) = $0 { value } else { nil }
        }
    }

    public func array(for key: SourceKitUID) -> [SourceKitValue]? {
        dictionaryValue(for: key).flatMap {
            if case .array(let value) = $0 { value } else { nil }
        }
    }

    public func dictionaryValue(for key: SourceKitUID) -> SourceKitValue? {
        guard case .dictionary(let dictionary) = value else {
            return nil
        }
        return dictionary[key]
    }
}
