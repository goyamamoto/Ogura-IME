import Foundation

/// Where the tests' sessions keep their learning data: a fresh directory for each test run, so no run depends on what
/// earlier runs learned (the system's temporary directory kept a candidate learned long ago at the top)
let testLearningDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ogura-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()
