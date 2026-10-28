import Foundation

public struct TensorInfo: Sendable, Equatable {
    public let name: String
    public let dtype: String
    public let shape: [Int]
    public let dataOffsets: Range<Int>
}

public enum SafetensorsError: Error, CustomStringConvertible {
    case tooShort
    case badHeaderLength(UInt64)
    case badJSON(String)
    case badTensor(String)

    public var description: String {
        switch self {
        case .tooShort: "file shorter than the 8-byte header length"
        case .badHeaderLength(let n): "implausible header length \(n)"
        case .badJSON(let m): "invalid safetensors header: \(m)"
        case .badTensor(let m): "invalid tensor entry: \(m)"
        }
    }
}

/// Reads the JSON header of a `.safetensors` file without mapping the weights.
public struct SafetensorsFile: Sendable {
    public let url: URL
    public let tensors: [String: TensorInfo]
    public let headerLength: Int

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw SafetensorsError.tooShort
        }
        let n = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard n > 0, n < 100_000_000 else { throw SafetensorsError.badHeaderLength(n) }
        guard let raw = try handle.read(upToCount: Int(n)) else { throw SafetensorsError.tooShort }

        let object: [String: Any]
        do {
            guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw SafetensorsError.badJSON("root is not an object")
            }
            object = o
        } catch let e as SafetensorsError {
            throw e
        } catch {
            throw SafetensorsError.badJSON(String(describing: error))
        }

        var parsed: [String: TensorInfo] = [:]
        for (name, value) in object where name != "__metadata__" {
            guard let entry = value as? [String: Any],
                  let dtype = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int],
                  let offs = entry["data_offsets"] as? [Int], offs.count == 2, offs[0] <= offs[1]
            else { throw SafetensorsError.badTensor(name) }
            parsed[name] = TensorInfo(
                name: name, dtype: dtype, shape: shape, dataOffsets: offs[0] ..< offs[1]
            )
        }
        self.tensors = parsed
        self.headerLength = 8 + Int(n)
    }

    /// Byte range of the tensor payload inside the file.
    public func payloadRange(for name: String) -> Range<Int>? {
        guard let t = tensors[name] else { return nil }
        let base = headerLength
        return (base + t.dataOffsets.lowerBound) ..< (base + t.dataOffsets.upperBound)
    }
}

/// `model.safetensors.index.json`: tensor name -> shard file.
public struct ModelIndex: Sendable {
    public let weightMap: [String: String]
    public let totalSize: Int

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["weight_map"] as? [String: String]
        else { throw SafetensorsError.badJSON("missing weight_map") }
        self.weightMap = map
        self.totalSize = (root["metadata"] as? [String: Any])?["total_size"] as? Int ?? 0
    }

    public func shards() -> [String: [String]] {
        Dictionary(grouping: weightMap.keys) { weightMap[$0]! }
    }
}
