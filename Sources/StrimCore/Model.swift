import Foundation

public struct ModelID: Hashable, Sendable {
    public let repo: String
    public let revision: String
    public init(repo: String, revision: String) { self.repo = repo; self.revision = revision }
    public static let qwen38_27b = ModelID(repo: "mlx-community/Qwen3.8-27B-4bit", revision: "main")
}

public enum Quantization: Int, Sendable, CaseIterable {
    case q4 = 4
    case q6 = 6
    case q8 = 8
}

public struct RuntimeConfig: Sendable {
    public var model: ModelID
    public var quant: Quantization
    public var contextTokens: Int
    public var prefillStep: Int
    public var mtpDepth: Int
    public var wiredLimitGB: Int

    public init(model: ModelID = .qwen38_27b, quant: Quantization = .q4,
                contextTokens: Int = 65_536, prefillStep: Int = 2_048,
                mtpDepth: Int = 3, wiredLimitGB: Int = 44) {
        self.model = model; self.quant = quant; self.contextTokens = contextTokens
        self.prefillStep = prefillStep; self.mtpDepth = mtpDepth; self.wiredLimitGB = wiredLimitGB
    }
    public static let measuredSpeed = RuntimeConfig()
    public static let measuredQuality = RuntimeConfig(quant: .q8, contextTokens: 32_768)
}
