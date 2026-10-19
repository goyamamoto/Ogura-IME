// Register an installed Ogura as an input source of the current login session, so it appears in the input source list
// without logging out. Registration is per session: run it as the account that uses Ogura, not as root.
//
// Developers run it through the interpreter: swift Tools/RegisterInputSource.swift [path to Ogura.app]
// pkgbuild.sh compiles it into the installer package, whose postinstall runs it as the logged-in user.
import Carbon
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Library/Input Methods/Ogura.app"
guard FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("not found: \(path)\n".utf8))
    exit(1)
}
let status = TISRegisterInputSource(URL(fileURLWithPath: path) as CFURL)
guard status == noErr else {
    FileHandle.standardError.write(Data("TISRegisterInputSource failed: \(status)\n".utf8))
    exit(1)
}
print("registered: \(path)")
