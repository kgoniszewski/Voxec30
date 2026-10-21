import CoreText
import UIKit

/// Pliki tworzone przez Janka trafiają do folderu Dokumenty aplikacji
/// (widocznego w aplikacji Pliki → Na moim iPhonie → Janek).
enum DocumentsFolder {
    static var url: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func uniqueURL(base: String, ext: String) -> URL {
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = safe.isEmpty ? "Dokument" : safe
        var candidate = url.appendingPathComponent("\(name).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathComponent("\(name) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}

enum PDFMaker {
    /// Prosty PDF A4 z tytułem i akapitami, z automatycznym łamaniem stron.
    static func make(title: String, body: String, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 56
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold)]
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 4
        bodyStyle.paragraphSpacing = 8
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .paragraphStyle: bodyStyle]

        let text = NSMutableAttributedString(string: title + "\n\n", attributes: titleAttributes)
        text.append(NSAttributedString(string: body, attributes: bodyAttributes))
        let framesetter = CTFramesetterCreateWithAttributedString(text)

        try renderer.writePDF(to: url) { context in
            var location = 0
            while location < text.length {
                context.beginPage()
                let path = CGPath(rect: page.insetBy(dx: margin, dy: margin), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, cg)
                cg.restoreGState()
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { break }
                location += visible.length
            }
        }
    }
}

struct CreateTextFileTool: AssistantTool {
    let name = "document_create_text"
    let description = "Tworzy plik tekstowy (.txt lub .md) z podyktowaną treścią w folderze Janek w aplikacji Pliki."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "file_name": JSONSchema.string("Nazwa pliku bez rozszerzenia"),
            "content": JSONSchema.string("Treść pliku"),
            "format": JSONSchema.enumeration(["txt", "md"], "Format, domyślnie txt"),
        ], required: ["file_name", "content"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = DocumentsFolder.uniqueURL(base: try input.requiredString("file_name"), ext: input.optionalString("format") ?? "txt")
        try input.requiredString("content").write(to: url, atomically: true, encoding: .utf8)
        if context.isAppInForeground { context.present(.document(url)) }
        return .ok("Utworzono plik \(url.lastPathComponent) w aplikacji Pliki → Janek.")
    }
}

struct CreatePDFTool: AssistantTool {
    let name = "document_create_pdf"
    let description = "Tworzy dokument PDF (np. pismo, listę, notatkę ze spotkania) i zapisuje go w folderze Janek w aplikacji Pliki. Możesz zredagować treść zgodnie z prośbą użytkownika."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "file_name": JSONSchema.string("Nazwa pliku bez rozszerzenia"),
            "title": JSONSchema.string("Tytuł dokumentu"),
            "body": JSONSchema.string("Treść dokumentu; akapity rozdzielone pustą linią"),
        ], required: ["file_name", "title", "body"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = DocumentsFolder.uniqueURL(base: try input.requiredString("file_name"), ext: "pdf")
        try PDFMaker.make(title: try input.requiredString("title"), body: try input.requiredString("body"), to: url)
        if context.isAppInForeground { context.present(.document(url)) }
        return .ok("Utworzono PDF \(url.lastPathComponent) w aplikacji Pliki → Janek.")
    }
}

struct TakePhotoTool: AssistantTool {
    let name = "camera_take_photo"
    let description = "Otwiera aparat, by zrobić zdjęcie; zdjęcie zapisuje się w Zdjęciach. Działa tylko, gdy telefon jest odblokowany i Janek jest na ekranie."
    var inputSchema: JSONValue { JSONSchema.object([:]) }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard context.isAppInForeground else { return .error("Aparat wymaga, by aplikacja była na ekranie.") }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { throw ToolError.unavailable("aparat") }
        context.present(.camera)
        return .ok("Aparat jest otwarty – użytkownik robi zdjęcie spustem lub przyciskiem Aparat.")
    }
}
