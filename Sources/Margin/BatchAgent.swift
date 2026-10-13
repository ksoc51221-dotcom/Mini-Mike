import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum BatchKind: String, CaseIterable, Equatable {
    case heicToJpg, mergePDFs, ocrToText

    var title: String {
        switch self {
        case .heicToJpg: return "Convert HEIC photos to JPG"
        case .mergePDFs: return "Merge PDFs"
        case .ocrToText: return "Read text from images"
        }
    }
}

/// Repetitive file jobs. Each makes NEW files next to the originals (which are never changed), shows what it will make
/// first, and can be undone (the new files go to the Trash).
final class BatchAgent {
    private let kind: BatchKind
    private var files: [URL]
    private var ledgerBox = FileSafety.Ledger(title: "")

    init(kind: BatchKind, files: [URL]) {
        self.kind = kind
        self.files = files
    }

    // MARK: Which files

    private static func isHEIC(_ u: URL) -> Bool { ["heic", "heif"].contains(u.pathExtension.lowercased()) }
    private static func isPDF(_ u: URL) -> Bool { u.pathExtension.lowercased() == "pdf" }
    private static func isImage(_ u: URL) -> Bool { ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"].contains(u.pathExtension.lowercased()) }

    /// Without dropped files, HEIC conversion looks on the Desktop and in Downloads.
    private func inputs() -> [URL] {
        var urls = files
        if urls.isEmpty, kind == .heicToJpg {
            for root in FileSafety.roots.prefix(2) {
                urls += ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            }
        }
        switch kind {
        case .heicToJpg: return urls.filter(Self.isHEIC)
        case .mergePDFs: return urls.filter(Self.isPDF).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .ocrToText: return urls.filter { Self.isImage($0) || Self.isPDF($0) }
        }
    }

    /// Where a new file goes: beside the original if that's an allowed folder, otherwise a "Margin Output" folder on the Desktop.
    private func outputFolder(for source: URL) -> URL {
        let beside = source.deletingLastPathComponent()
        if FileSafety.root(containing: beside.appendingPathComponent("x")) != nil { return beside }
        return (FileSafety.roots.first ?? beside).appendingPathComponent("Margin Output", isDirectory: true)
    }

    // MARK: Plan and run

    func run(_ task: BackgroundTask) {
        task.onCancel = { task.cancelRequested = true }
        let ins = inputs()
        switch (kind, ins.count) {
        case (_, 0):
            return task.fail(kind == .heicToJpg ? "No HEIC photos on your Desktop or in Downloads. Drop some on the task box."
                                                : "Drop the files onto the task box first.")
        case (.mergePDFs, 1):
            return task.fail("Merging needs two or more PDFs. Drop them together on the task box.")
        default: break
        }
        let lines: [String]
        switch kind {
        case .heicToJpg: lines = ins.map { "\($0.lastPathComponent)  →  \($0.deletingPathExtension().lastPathComponent).jpg" }
        case .mergePDFs: lines = ins.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
        case .ocrToText: lines = ins.map { "\($0.lastPathComponent)  →  \($0.deletingPathExtension().lastPathComponent).txt" }
        }
        let title: String
        switch kind {
        case .heicToJpg: title = "Make \(ins.count) JPG cop\(ins.count == 1 ? "y" : "ies") of HEIC photos"
        case .mergePDFs: title = "Merge \(ins.count) PDFs into one, in this order"
        case .ocrToText: title = "Read the text in \(ins.count) file\(ins.count == 1 ? "" : "s") and save it as .txt"
        }
        task.plan = TaskPlan(headline: kind.title, groups: [PlanGroup(key: kind.rawValue, title: title,
                                                                      subtitle: "Your originals aren't changed. New files go next to them.",
                                                                      symbol: "doc.badge.plus", ops: [], files: lines)])
        task.detail = "Waiting for your OK"
        task.state = .needsApproval
        task.onApprove = { [self] t in self.approve(t, ins) }
    }

    private func approve(_ task: BackgroundTask, _ ins: [URL]) {
        task.state = .working
        task.plan = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var ledger = FileSafety.Ledger(title: task.title)
            var made: [URL] = []
            var problems: [String] = []
            switch kind {
            case .heicToJpg:
                for (i, u) in ins.enumerated() {
                    if task.cancelRequested { break }
                    task.progress("Converting: \(i + 1) of \(ins.count)", Double(i) / Double(ins.count))
                    if let data = Self.jpegData(from: u) {
                        do { made.append(try FileSafety.createFile(data, at: outputFolder(for: u).appendingPathComponent(u.deletingPathExtension().lastPathComponent + ".jpg"), ledger: &ledger)) }
                        catch { problems.append("\(u.lastPathComponent): \(error.localizedDescription)") }
                    } else { problems.append("\(u.lastPathComponent): couldn't be read") }
                }
            case .mergePDFs:
                task.progress("Merging…")
                if let data = Self.mergedPDF(ins) {
                    let name = ins[0].deletingPathExtension().lastPathComponent + " + \(ins.count - 1) more.pdf"
                    do { made.append(try FileSafety.createFile(data, at: outputFolder(for: ins[0]).appendingPathComponent(name), ledger: &ledger)) }
                    catch { problems.append(error.localizedDescription) }
                } else { problems.append("The PDFs couldn't be read") }
            case .ocrToText:
                for (i, u) in ins.enumerated() {
                    if task.cancelRequested { break }
                    task.progress("Reading: \(i + 1) of \(ins.count)", Double(i) / Double(ins.count))
                    if let text = Self.text(from: u), !text.isEmpty {
                        do { made.append(try FileSafety.createFile(Data(text.utf8), at: outputFolder(for: u).appendingPathComponent(u.deletingPathExtension().lastPathComponent + ".txt"), ledger: &ledger)) }
                        catch { problems.append("\(u.lastPathComponent): \(error.localizedDescription)") }
                    } else { problems.append("\(u.lastPathComponent): no text found") }
                }
            }
            FileSafety.save(ledger)
            ledgerBox = ledger
            DispatchQueue.main.async {
                var report = TaskReport(headline: "Made \(made.count) new file\(made.count == 1 ? "" : "s")",
                                        lines: problems.isEmpty ? [] : ["Skipped: " + problems.prefix(3).joined(separator: "; ")],
                                        links: made.prefix(6).map { TaskLink(title: $0.lastPathComponent, url: $0) })
                if let folder = made.first?.deletingLastPathComponent() { report.links.append(TaskLink(title: "Open folder", url: folder)) }
                task.onUndo = { [self] t in
                    DispatchQueue.global().async {
                        var l = self.ledgerBox
                        let r = FileSafety.undo(&l)
                        DispatchQueue.main.async {
                            t.undone = true
                            t.canUndo = false
                            t.detail = "Undone: removed \(r.restored) new file\(r.restored == 1 ? "" : "s")"
                            t.report = TaskReport(headline: t.detail)
                        }
                    }
                }
                task.finish(report, canUndo: !made.isEmpty)
            }
        }
    }

    // MARK: The work

    static func jpegData(from url: URL, quality: Double = 0.88) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func mergedPDF(_ urls: [URL]) -> Data? {
        let merged = PDFDocument()
        for u in urls {
            guard let doc = PDFDocument(url: u) else { return nil }
            for i in 0..<doc.pageCount { if let page = doc.page(at: i) { merged.insert(page, at: merged.pageCount) } }
        }
        return merged.pageCount > 0 ? merged.dataRepresentation() : nil
    }

    static func text(from url: URL) -> String? {
        if isPDF(url) {
            guard let doc = PageReader.readPDF(url, title: url.lastPathComponent) else { return nil }
            return doc.passages.map { ($0.page.map { "[page \($0)]\n" } ?? "") + $0.text }.joined(separator: "\n\n")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return OCR.text(in: image)
    }
}
