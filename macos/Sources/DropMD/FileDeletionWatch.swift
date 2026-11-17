import Foundation

/// 文件被别的程序删掉时通知一次（如 Edge 删除下载记录会删掉它的临时文件）。
/// 只管删除：在访达里移动、扔进废纸篓算改名，那是用户自己挪走的。只依赖 Foundation，可单独测试（tools/test_editor.sh）。
final class FileDeletionWatch {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, queue: DispatchQueue = .main, onDelete: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .delete, queue: queue)
        source.setEventHandler(handler: onDelete)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }   // 不取消的话监视一直在，文件也一直开着

    /// 文件不见了时要不要把编辑区的内容存回原处：改过才写回；没改过的不写，用户可能就是想删掉它。
    /// 系统保存时会用新文件替换旧文件（也算一次“删除”），文件还在就不用写
    static func shouldWriteBack(fileExists: Bool, edited: Bool, text: String, diskText: String?) -> Bool {
        !fileExists && (edited || text != diskText)
    }
}
