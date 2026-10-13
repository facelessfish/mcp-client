import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Getting a reply's pixels out of the window
//
// The Result tab can draw an image; these are the two ways to get one *out* of
// the window: the right-click panel, and a drag onto the Desktop (or into a mail
// message, or anywhere else a file goes). Both move `ReplyImage.data` — the bytes
// the server sent — and never a re-encoding of the `NSImage`. Pixels that pass
// through AppKit on their way to disk come back a TIFF at whatever resolution the
// draw asked for; a debugger that resampled the reply before saving it would be
// reporting on its own formatting, which is the one sin this app was built to
// avoid everywhere else.
//
// No isolation annotations, exactly like `Clip` in Utilities.swift: these run from
// view gestures, already on the main thread.

enum ImageActions {

    // MARK: - What the bytes are

    /// Filename extension for a payload, sniffed off its own magic numbers first
    /// and only then from the mimeType the content block announced. A server that
    /// calls a JPEG `image/png` is exactly the kind of thing this app exists to
    /// catch — and the file it hands you should still open.
    static func fileExtension(for data: Data, announcedMIME: String?) -> String {
        let head = [UInt8](data.prefix(16))
        func bytes(_ offset: Int, _ want: [UInt8]) -> Bool {
            guard head.count >= offset + want.count else { return false }
            return Array(head[offset..<(offset + want.count)]) == want
        }
        func text(_ offset: Int, _ want: String) -> Bool { bytes(offset, [UInt8](want.utf8)) }

        if bytes(0, [0x89, 0x50, 0x4E, 0x47]) { return "png" }                 // \x89PNG
        if bytes(0, [0xFF, 0xD8, 0xFF]) { return "jpg" }                       // JPEG SOI
        if text(0, "GIF8") { return "gif" }                                    // GIF87a / GIF89a
        if text(0, "RIFF"), text(8, "WEBP") { return "webp" }
        if bytes(0, [0x49, 0x49, 0x2A, 0x00]) || bytes(0, [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if bytes(0, [0x00, 0x00, 0x01, 0x00]) { return "ico" }
        if text(0, "<?xml") || text(0, "<svg") { return "svg" }                // AppKit draws these too
        if let mime = announcedMIME?.trimmed.lowercased(), !mime.isEmpty,
           let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            return ext
        }
        // Unrecognized and unnamed: an honest unknown, not a guessed `.png`.
        return "img"
    }

    /// The line over a drawn image: what the block called itself — or what its
    /// bytes turn out to be, when it called itself nothing — and the size of
    /// those bytes. The *announced* type is the fact under debug, so it wins here;
    /// `fileExtension` is the other function on purpose.
    static func note(for image: ReplyImage) -> String {
        let announced = image.mime?.trimmed ?? ""
        let kind = announced.isEmpty
            ? fileExtension(for: image.data, announcedMIME: nil).uppercased()
            : announced
        return "\(kind) · \(ByteSize.label(image.data.count))"
    }

    /// `add-1.png`: the tool's wire name, the block's place in the reply, the
    /// extension the bytes really have. The wire name is sanitized because it
    /// arrived over HTTP from a server someone wrote in an afternoon — a `/` in a
    /// tool name is a path, not a character.
    static func suggestedName(toolName: String, index: Int, image: ReplyImage) -> String {
        let base = sanitize(toolName)
        let ext = fileExtension(for: image.data, announcedMIME: image.mime)
        return "\(base)-\(index + 1).\(ext)"
    }

    private static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let keeps = (scalar.value >= 0x61 && scalar.value <= 0x7A)      // a…z
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)          // A…Z
                || (scalar.value >= 0x30 && scalar.value <= 0x39)          // 0…9
                || scalar == "-" || scalar == "_" || scalar == "."
            out += keeps ? String(scalar) : "_"
        }
        while let first = out.first, first == "." || first == "-" || first == "_" {
            out.removeFirst()                                             // no dotted names either
        }
        return out.isEmpty ? "image" : String(out.prefix(60))
    }

    // MARK: - Save

    /// A save panel for one image, sheet-modal to the window it was asked from.
    /// No content-type filter and no forced directory: the name arrives with the
    /// extension the bytes actually have, the panel remembers where the user last
    /// saved, and a debugger's user is allowed to call the file `x.bin`.
    static func save(_ image: ReplyImage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Save Image"
        panel.prompt = "Save Image"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.message = "\(note(for: image)) — written exactly as the reply sent it."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try image.data.write(to: url, options: .atomic)
            } catch {
                reportFailure("Could not save the image.", at: url, error: error)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin { finish($0) }
        }
    }

    /// Pixels onto the pasteboard — what a right-click on a picture is for. The
    /// image, not a path: AppKit writes its own representations, so the paste
    /// lands in Preview, a browser or a chat as a picture. The base64 that
    /// carried it stays where it always was, one tab away in Raw.
    static func copy(_ image: ReplyImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let pixels: [NSPasteboardWriting] = [image.image]
        _ = pasteboard.writeObjects(pixels)
    }

    // MARK: - Drag

    /// The provider for dragging one image out — onto the Desktop and into
    /// Finder's business. Finder takes a **file**, not a promise it has to come
    /// back and ask us about, so the bytes go to a file of their own under the
    /// name they should land with, and that URL is what travels. If even that
    /// fails (a full disk, a denied temp folder) the pixels go instead: a drag
    /// that silently does nothing is worse than one that carries less.
    static func dragProvider(_ image: ReplyImage, suggestedName: String) -> NSItemProvider {
        if let url = stage(image, named: suggestedName) {
            return NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider(object: image.image)
    }

    /// The staging corner of the temporary directory. A staged file lives as long
    /// as the drag needs and an hour longer, then is swept on the next pass —
    /// temporary items are the OS's business eventually, but a folder that only
    /// ever grows is this app's manners.
    private static func stage(_ image: ReplyImage, named name: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent(AppInfo.clientName, isDirectory: true)
            .appendingPathComponent("dragged", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            sweep(dir)
            let url = dir.appendingPathComponent(name)
            try image.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func sweep(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - Failure

    /// Saving failed loudly: a panel that closed and produced nothing would be
    /// the worst kind of silent answer this app argues against.
    private static func reportFailure(_ what: String, at url: URL, error: Error) {
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = "\(url.path)\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
