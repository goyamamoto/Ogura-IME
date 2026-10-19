import Foundation
import Testing

@testable import Core

#if os(macOS)
@Suite("AppContainer")
struct AppContainerTests {
    @Test("保存先は Application Support 直下の Ogura フォルダ")
    func resolvesDirectoriesUnderApplicationSupport() {
        let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)

        #expect(
            AppContainer.applicationSupportDirectoryURL(libraryApplicationSupportURL: applicationSupport).path
                == "/Users/example/Library/Application Support/Ogura"
        )
    }

    @Test("学習データと個人最適化モデルは Ogura フォルダの下に置く")
    func memoryAndPersonalizationLiveUnderApplicationSupport() {
        let base = AppContainer.applicationSupportDirectoryURL().path
        #expect(AppContainer.memoryDirectoryURL().path == base + "/memory")
        #expect(AppContainer.personalizationDirectoryURL().path == base + "/p13n_v1")
    }
}
#endif
