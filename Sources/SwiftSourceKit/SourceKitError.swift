import Foundation

public enum SourceKitError: Error, Equatable, CustomStringConvertible, Sendable {
    case sourceKitUnavailable(String)
    case missingSymbol(String)
    case incompatibleSourceKitD(String)
    case invalidRequest(String)
    case requestFailed(kind: Int64, description: String)
    case responseDecodeFailed(String)

    public var description: String {
        switch self {
        case .sourceKitUnavailable(let message):
            "sourcekitd unavailable: \(message)"
        case .missingSymbol(let symbol):
            "sourcekitd symbol missing: \(symbol)"
        case .incompatibleSourceKitD(let message):
            "incompatible sourcekitd runtime: \(message)"
        case .invalidRequest(let message):
            "invalid sourcekitd request: \(message)"
        case .requestFailed(let kind, let description):
            "sourcekitd request failed (\(kind)): \(description)"
        case .responseDecodeFailed(let message):
            "sourcekitd response decode failed: \(message)"
        }
    }
}
