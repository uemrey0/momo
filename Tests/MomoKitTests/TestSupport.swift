import Foundation
import Testing

@testable import MomoKit

func temporaryStore() -> MomoStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("momo-tests-\(UUID().uuidString)")
        .appendingPathComponent("data.json")
    return MomoStore(fileURL: url)
}
