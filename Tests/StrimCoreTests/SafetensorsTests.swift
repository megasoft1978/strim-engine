import Foundation
import Testing
@testable import StrimCore

private func makeSafetensors(_ json: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("model.safetensors")
    var data = Data()
    var n = UInt64(json.utf8.count).littleEndian
    withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
    data.append(json.data(using: .utf8)!)
    data.append(Data(repeating: 0, count: 16))
    try data.write(to: url)
    return url
}

@Test func parsesHeaderAndPayloadOffsets() throws {
    let json = #"{"w":{"dtype":"U32","shape":[2,4],"data_offsets":[0,8]},"__metadata__":{"format":"mlx"}}"#
    let url = try makeSafetensors(json)
    let f = try SafetensorsFile(url: url)
    #expect(f.tensors.count == 1)
    #expect(f.tensors["w"]?.shape == [2, 4])
    #expect(f.tensors["w"]?.dtype == "U32")
    #expect(f.payloadRange(for: "w") == f.headerLength ..< (f.headerLength + 8))
}

@Test func rejectsMissingOffsets() throws {
    let json = #"{"w":{"dtype":"U32","shape":[2]}}"#
    let url = try makeSafetensors(json)
    #expect(throws: SafetensorsError.self) { _ = try SafetensorsFile(url: url) }
}

@Test func indexGroupsShards() throws {
    let json = #"{"metadata":{"total_size":42},"weight_map":{"a":"s1","b":"s1","c":"s2"}}"#
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("i-\(UUID().uuidString).json")
    try json.data(using: .utf8)!.write(to: url)
    let idx = try ModelIndex(url: url)
    #expect(idx.totalSize == 42)
    #expect(idx.shards()["s1"]?.sorted() == ["a", "b"])
}
