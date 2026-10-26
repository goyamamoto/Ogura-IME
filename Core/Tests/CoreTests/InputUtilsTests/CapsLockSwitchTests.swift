import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// macOS switches input sources with the Caps Lock key (its "Caps Lock to switch" setting) only for input methods that
/// declare TICapsLockLanguageSwitchCapable, at the top of Info.plist and in each input mode: declared only at the top,
/// a short press still turned on Caps Lock in Ogura's modes
@Test("Info.plist は Caps Lock キーでの入力ソースの切り替えに、全体とすべての入力モードで対応を示す")
func infoPlistDeclaresCapsLockSwitching() throws {
    let data = try Data(contentsOf: repository.appendingPathComponent("Ogura/Info.plist"))
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: 0, format: nil) as? [String: Any])
    #expect(plist["TICapsLockLanguageSwitchCapable"] as? Bool == true)
    let modeDictionary = try #require(plist["ComponentInputModeDict"] as? [String: Any])
    let modes = try #require(modeDictionary["tsInputModeListKey"] as? [String: [String: Any]])
    #expect(!modes.isEmpty)
    for (mode, properties) in modes {
        #expect(properties["TICapsLockLanguageSwitchCapable"] as? Bool == true, "\(mode) does not declare it")
    }
}
