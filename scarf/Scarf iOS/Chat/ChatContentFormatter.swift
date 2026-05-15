import Foundation

/// Splits a chat message body into alternating text, fenced-code, and media
/// segments so ChatView can render each part appropriately. Text gets the
/// existing AttributedString(markdown:) path; code gets a horizontally-
/// scrollable monospaced block; standalone `MEDIA:` lines become inline
/// attachments.
///
/// Keeps the parser deliberately simple: it recognises the common fenced form
/// (```\n...\n``` and ```lang\n...\n```) and only treats `MEDIA:` as special
/// outside fences. Inline `backticks` stay in the text segment —
/// AttributedString handles those fine.
enum ChatContentFormatter {

    enum Segment: Equatable {
        case text(String)
        case code(language: String?, body: String)
        case media(ChatMediaAttachment)
    }

    /// Split the given message body into an ordered list of segments.
    /// A body with no fenced code and no MEDIA lines yields a single `.text` segment.
    static func segments(for body: String) -> [Segment] {
        guard body.contains("```") || body.localizedCaseInsensitiveContains("MEDIA:") else {
            return [.text(body)]
        }

        var result: [Segment] = []
        let lines = body.components(separatedBy: "\n")
        var pendingText: [String] = []
        var pendingCode: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            let text = pendingText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(.text(text))
            }
            pendingText = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inCode && line.hasPrefix("```") {
                flushText()
                inCode = true
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
            } else if inCode && line.hasPrefix("```") {
                result.append(.code(language: codeLanguage, body: pendingCode.joined(separator: "\n")))
                pendingCode = []
                codeLanguage = nil
                inCode = false
            } else if inCode {
                pendingCode.append(line)
            } else if trimmed.uppercased().hasPrefix("MEDIA:") {
                flushText()
                let rawMedia = String(trimmed.dropFirst("MEDIA:".count))
                if let media = ChatMediaAttachment(rawValue: rawMedia) {
                    result.append(.media(media))
                } else {
                    pendingText.append(line)
                }
            } else {
                pendingText.append(line)
            }
        }

        if inCode {
            let unterminated = "```" + (codeLanguage.map { $0 } ?? "") + "\n" + pendingCode.joined(separator: "\n")
            pendingText.append(unterminated)
        }
        flushText()

        return result
    }
}

struct ChatMediaAttachment: Equatable, Identifiable {
    enum Kind: Equatable {
        case image
        case video
        case file
    }

    let id: String
    let rawReference: String
    let url: URL
    let filePath: String?
    let kind: Kind

    var displayName: String {
        if let filePath {
            return (filePath as NSString).lastPathComponent.isEmpty ? filePath : (filePath as NSString).lastPathComponent
        }
        return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
    }

    var isFileBacked: Bool { filePath != nil }

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsedURL: URL
        let path: String?
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            parsedURL = url
            path = nil
        } else if let url = URL(string: trimmed), url.scheme?.lowercased() == "file" {
            parsedURL = url
            path = url.path
        } else {
            parsedURL = URL(fileURLWithPath: trimmed)
            path = trimmed
        }

        self.rawReference = trimmed
        self.url = parsedURL
        self.filePath = path
        self.id = trimmed

        let ext = (path.map { ($0 as NSString).pathExtension } ?? parsedURL.pathExtension).lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext) {
            self.kind = .image
        } else if ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext) {
            self.kind = .video
        } else {
            self.kind = .file
        }
    }
}
