import Foundation

/// Where a test's session keeps its learning data: a fresh directory for each session, so no test depends on what
/// another test's session learned (the system's temporary directory kept a candidate learned long ago at the top, and
/// a sentence committed by one test came back as one clause in another)
func freshTestLearningDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ogura-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
