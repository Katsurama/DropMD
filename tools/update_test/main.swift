import Foundation

// 用假的 App（只有 Info.plist）测试 AppUpdateInstaller：
// 1. 从 .zip 取出新版本；2. 包名或版本不对时拒绝；3. 等进程退出后替换旧版本。

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

// 模型下载的指纹核对：小文件用 Git 文件哈希，大文件用 SHA-256；对的放行、错的拒绝
do {
    let f = work.appendingPathComponent("model-file.txt")
    try! Data("hello\n".utf8).write(to: f)
    let ok = { (s: ModelDownloader.Sibling) in (try? ModelDownloader.verify(f, sibling: s)) != nil }
    check(ok(.init(rfilename: "a", size: 6, blobId: "ce013625030ba8dba906f756967f9e9ca394464a", lfs: nil)), "模型文件：Git 哈希正确时放行")
    check(!ok(.init(rfilename: "a", size: 6, blobId: "0000000000000000000000000000000000000000", lfs: nil)), "模型文件：Git 哈希不对时拒绝")
    check(ok(.init(rfilename: "a", size: 6, blobId: nil, lfs: .init(sha256: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03", size: 6))), "模型文件：SHA-256 正确时放行")
    check(!ok(.init(rfilename: "a", size: 6, blobId: nil, lfs: .init(sha256: String(repeating: "0", count: 64), size: 6))), "模型文件：SHA-256 不对时拒绝")
    check(!ok(.init(rfilename: "a", size: 6, blobId: nil, lfs: nil)), "模型文件：缺少哈希时拒绝")
}

func version(of app: URL) -> String? {
    NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
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
let wrongZip = makeZIP(id: "com.example.other", version: "2.0.0", name: "wrong")
check((try? AppUpdateInstaller.stage(package: wrongZip, to: staged, bundleID: id, version: "2.0.0")) == nil
      && !fm.fileExists(atPath: staged.path), "包名不对时拒绝")

// 版本不对：拒绝
let good = makeZIP(id: id, version: "2.0.0", name: "good")
check((try? AppUpdateInstaller.stage(package: good, to: staged, bundleID: id, version: "3.0.0")) == nil
      && !fm.fileExists(atPath: staged.path), "版本不对时拒绝")

// 正常：取出新版本
do {
    try AppUpdateInstaller.stage(package: good, to: staged, bundleID: id, version: "2.0.0")
    check(version(of: staged) == "2.0.0", "从 zip 取出新版本")
} catch {
    check(false, "从 zip 取出新版本（\(error)）")
}

// 等进程退出后替换
let sleeper = Process()
sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
sleeper.arguments = ["30"]
try! sleeper.run()
try! AppUpdateInstaller.replaceAfterExit(pid: sleeper.processIdentifier, app: app, staged: staged, relaunch: false)
try await Task.sleep(nanoseconds: 1_500_000_000)
check(version(of: app) == "1.0.0", "进程退出前不替换")
sleeper.terminate()
sleeper.waitUntilExit()
var replaced = false
for _ in 0..<20 where !replaced {
    try await Task.sleep(nanoseconds: 500_000_000)
    replaced = version(of: app) == "2.0.0"
}
check(replaced, "进程退出后换成新版本")
check(!fm.fileExists(atPath: staged.path) && !fm.fileExists(atPath: app.path + ".old"), "替换后不留临时文件")

// 替换失败（新版本不见了）：旧版本挪回原处，App 不会没了
do {
    let old = work.appendingPathComponent("Apps2/DropMD.app")
    makeApp(at: old, id: id, version: "1.0.0")
    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! exited.run()
    exited.waitUntilExit()
    try! AppUpdateInstaller.replaceAfterExit(pid: exited.processIdentifier, app: old,
                                             staged: work.appendingPathComponent("Apps2/不存在.app"), relaunch: false)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    check(version(of: old) == "1.0.0" && !fm.fileExists(atPath: old.path + ".old"), "替换失败时旧版本留在原处")
}

// 版本号比较：决定是否提示更新
func newer(_ a: String, _ b: String) -> Bool { AppVersion(a)! > AppVersion(b)! }
check(newer("0.1.0-beta.10", "0.1.0-beta.9"), "beta.10 比 beta.9 新")
check(newer("1.0.0", "1.0.0-beta.3"), "正式版比同号测试版新")
check(newer("0.2.0-beta.1", "0.1.9"), "大版本号优先")
check(AppVersion("v1.2")! == AppVersion("1.2.0")!, "v1.2 与 1.2.0 相同")
check(AppVersion("abc") == nil, "无效版本号")

// 选出要提示的新版本：默认只要正式版；勾了测试版才有 beta；版本号带 -beta 但漏标“预发布”也算测试版；草稿不要
do {
    func release(_ tag: String, pre: Bool = false, draft: Bool = false) -> ReleaseInfo {
        let json = #"{"tag_name":"\#(tag)","prerelease":\#(pre),"draft":\#(draft),"html_url":"https://example.com","assets":[]}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try! d.decode(ReleaseInfo.self, from: Data(json.utf8))
    }
    let list = [release("v1.0.0"), release("v1.1.0-beta.1", pre: true), release("v1.1.0-beta.2"), release("v2.0.0", draft: true)]
    check(ReleaseInfo.newest(list, includeBeta: false)?.tagName == "v1.0.0", "不要测试版时只提示正式版（漏标预发布的 beta 也不提示）")
    check(ReleaseInfo.newest(list, includeBeta: true)?.tagName == "v1.1.0-beta.2", "要测试版时提示最新的 beta")
    check(ReleaseInfo.newest(list + [release("v1.1.0")], includeBeta: true)?.tagName == "v1.1.0", "正式版出来后比同号 beta 优先")
    check(release("v1.1.0-beta.2").isBeta && !release("v1.0.0").isBeta, "按版本号认出测试版")
}

// 更新说明只显示界面语言那一段
let notes = "## DropMD 1.0\n\n**新功能**\n- 中文\n\n**English**\n- English\n\n**日本語**\n- 日本語\n\n---\n\n## DropMD 0.9\n\n- 旧中文\n\n**English**\n- old"
check(releaseNotes(notes, language: "zh") == "## DropMD 1.0\n\n**新功能**\n- 中文\n\n---\n\n## DropMD 0.9\n\n- 旧中文", "更新说明：简体只留中文")
check(releaseNotes(notes, language: "en") == "## DropMD 1.0\n\n- English\n\n---\n\n## DropMD 0.9\n\n- old", "更新说明：英文")
check(releaseNotes(notes, language: "ja").contains("- 日本語") && !releaseNotes(notes, language: "ja").contains("English"), "更新说明：日文")
check(releaseNotes(notes, language: "zh-Hant").contains("- 中文"), "更新说明：没有繁体时用中文")
check(releaseNotes("- 只有中文", language: "en") == "- 只有中文", "更新说明：没有英文时用中文")

// 引擎日志：接在后面写，不清空上次的；超过 1 MB 才清空
do {
    let log = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("logs/engine.log")
    for line in ["第一次\n", "第二次\n"] {
        let h = Engine.logHandle(file: log)
        try! h.write(contentsOf: Data(line.utf8))
        try! h.close()
    }
    check((try? String(contentsOf: log, encoding: .utf8)) == "第一次\n第二次\n", "引擎日志接着写")
    try! Data(count: (1 << 20) + 1).write(to: log)
    try! Engine.logHandle(file: log).close()
    check(((try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? -1) == 0, "引擎日志超过 1 MB 清空")
}

// 引擎“停止”：转换中又查了一次状态（如重新打开转换窗口），停止仍能结束转换。
// 两个引擎的输出是排队读的，查状态要等转换结束才返回，所以要在它返回前点停止
do {
    let fake = work.appendingPathComponent("fake-engine")
    try! "#!/bin/sh\nif [ \"$2\" = status ]; then echo '{}'; exit 0; fi\ncat >/dev/null\nexec sleep 30\n"
        .write(to: fake, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    setenv("DROPMD_ENGINE", fake.path, 1)
    let engine = Engine()
    let started = Date()
    let convert = Task { try await engine.run(["convert"], input: Data("{}".utf8)) { _ in } }
    try await Task.sleep(nanoseconds: 300_000_000)
    let status = Task { try await engine.run(["status"]) { _ in } }
    try await Task.sleep(nanoseconds: 300_000_000)
    engine.terminate()
    _ = try? await convert.value
    _ = try? await status.value
    check(Date().timeIntervalSince(started) < 10, "转换中查过状态后，停止仍能结束转换")
}

// 更新窗口里的说明拆成行：标题、列表（嵌套有层级）、普通文字、空行
check(releaseNoteLines("## DropMD 1.0.0\n\n- 表格可以删行\n  - 选中整行按退格\n* 右键菜单\n普通的一行 - 不是列表") ==
      [.heading("DropMD 1.0.0"), .blank, .bullet(level: 0, text: "表格可以删行"), .bullet(level: 1, text: "选中整行按退格"),
       .bullet(level: 0, text: "右键菜单"), .text("普通的一行 - 不是列表")], "更新说明拆成行")
print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
