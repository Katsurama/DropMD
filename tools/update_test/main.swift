import Foundation

// 用假的 App（只有 Info.plist）测试 AppUpdateInstaller：
// 1. 从 .zip / .dmg 取出新版本；2. 包名或版本不对时拒绝；3. 等进程退出后替换旧版本。

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
var failures = 0

func check(_ ok: Bool, _ name: String) {
    print((ok ? "通过 " : "失败 ") + name)
    if !ok { failures += 1 }
}

func makeApp(at url: URL, id: String, version: String) {
    let contents = url.appendingPathComponent("Contents")
    try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
    info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
}

func version(of app: URL) -> String? {
    NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
}

func makeDMG(id: String, version: String, name: String) -> URL {
    let src = work.appendingPathComponent("src-\(name)")
    makeApp(at: src.appendingPathComponent("DropMD.app"), id: id, version: version)
    try? fm.createSymbolicLink(atPath: src.appendingPathComponent("应用程序").path, withDestinationPath: "/Applications")
    let dmg = work.appendingPathComponent("\(name).dmg")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    p.arguments = ["create", "-quiet", "-fs", "HFS+", "-format", "ULFO", "-volname", "DropMD", "-srcfolder", src.path, dmg.path]
    try! p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, "hdiutil create 失败")
    return dmg
}

func makeZIP(id: String, version: String, name: String) -> URL {
    let src = work.appendingPathComponent("zipsrc-\(name)/DropMD.app")
    makeApp(at: src, id: id, version: version)
    let zip = work.appendingPathComponent("\(name).zip")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, zip.path]
    try! p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, "ditto 压缩失败")
    return zip
}

let id = "io.github.dropmd.app"
let app = work.appendingPathComponent("Apps/DropMD.app")
makeApp(at: app, id: id, version: "1.0.0")
let staged = work.appendingPathComponent("Apps/.DropMD-update.app")

// 包名不对：拒绝，不留下文件
let wrong = makeDMG(id: "com.example.other", version: "2.0.0", name: "wrong")
check((try? AppUpdateInstaller.stage(package: wrong, to: staged, bundleID: id, version: "2.0.0")) == nil
      && !fm.fileExists(atPath: staged.path), "包名不对时拒绝")

// 版本不对：拒绝
let good = makeDMG(id: id, version: "2.0.0", name: "good")
check((try? AppUpdateInstaller.stage(package: good, to: staged, bundleID: id, version: "3.0.0")) == nil
      && !fm.fileExists(atPath: staged.path), "版本不对时拒绝")

// zip：包名不对时拒绝，正常时取出新版本
let wrongZip = makeZIP(id: "com.example.other", version: "2.0.0", name: "wrong")
check((try? AppUpdateInstaller.stage(package: wrongZip, to: staged, bundleID: id, version: "2.0.0")) == nil
      && !fm.fileExists(atPath: staged.path), "zip 包名不对时拒绝")
do {
    try AppUpdateInstaller.stage(package: makeZIP(id: id, version: "2.0.0", name: "good"), to: staged, bundleID: id, version: "2.0.0")
    check(version(of: staged) == "2.0.0", "从 zip 取出新版本")
} catch {
    check(false, "从 zip 取出新版本（\(error)）")
}

// 正常：从 dmg 取出新版本
do {
    try AppUpdateInstaller.stage(package: good, to: staged, bundleID: id, version: "2.0.0")
    check(version(of: staged) == "2.0.0", "从 dmg 取出新版本")
} catch {
    check(false, "从 dmg 取出新版本（\(error)）")
}

// 等进程退出后替换
let sleeper = Process()
sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
sleeper.arguments = ["30"]
try! sleeper.run()
try! AppUpdateInstaller.replaceAfterExit(pid: sleeper.processIdentifier, app: app, staged: staged, relaunch: false)
Thread.sleep(forTimeInterval: 1.5)
check(version(of: app) == "1.0.0", "进程退出前不替换")
sleeper.terminate()
sleeper.waitUntilExit()
var replaced = false
for _ in 0..<20 where !replaced {
    Thread.sleep(forTimeInterval: 0.5)
    replaced = version(of: app) == "2.0.0"
}
check(replaced, "进程退出后换成新版本")
check(!fm.fileExists(atPath: staged.path) && !fm.fileExists(atPath: app.path + ".old"), "替换后不留临时文件")

// 版本号比较：决定是否提示更新
func newer(_ a: String, _ b: String) -> Bool { AppVersion(a)! > AppVersion(b)! }
check(newer("0.1.0-beta.10", "0.1.0-beta.9"), "beta.10 比 beta.9 新")
check(newer("1.0.0", "1.0.0-beta.3"), "正式版比同号测试版新")
check(newer("0.2.0-beta.1", "0.1.9"), "大版本号优先")
check(AppVersion("v1.2")! == AppVersion("1.2.0")!, "v1.2 与 1.2.0 相同")
check(AppVersion("abc") == nil, "无效版本号")

print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
