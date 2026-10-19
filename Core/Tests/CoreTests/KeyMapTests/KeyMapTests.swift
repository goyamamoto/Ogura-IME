import Core
import Testing

@Test func testh2z() async throws {
    // Half-width character to full-width character
    #expect(KeyMap.h2zMap("¥") == "￥")
    // Multiple characters are not supported
    #expect(KeyMap.h2zMap("a") == nil)
}
