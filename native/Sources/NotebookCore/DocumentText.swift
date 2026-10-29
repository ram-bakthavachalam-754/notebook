import Foundation
import CoreGraphics
import ImageIO
import Compression
import PDFKit
import Vision
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Turns an uploaded file into searchable text plus small rendered previews, with
/// the same code inside the Mac helper and the iPhone app. Everything runs on the
/// device: PDFKit for PDF text, Vision for recognizing text in images and scanned
/// pages, ImageIO for previews, and a small zip reader for Office documents.
/// Nothing here touches the network or the record store.
public enum DocumentText {
    public static let maxBytes = 25 * 1024 * 1024
    public static let maxCharacters = 2_000_000
    static let previewPixels = 1600, thumbnailPixels = 320, recognizePixels = 2400, recognizedPages = 40

    static let extensions: [String:String] = [
        "pdf":"application/pdf","png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","webp":"image/webp","heic":"image/heic","heif":"image/heif","tif":"image/tiff","tiff":"image/tiff","bmp":"image/bmp",
        "txt":"text/plain","text":"text/plain","log":"text/plain","md":"text/markdown","markdown":"text/markdown","csv":"text/csv","tsv":"text/tab-separated-values","json":"application/json","html":"text/html","htm":"text/html","xml":"text/xml","rtf":"text/rtf","yaml":"text/yaml","yml":"text/yaml","ics":"text/calendar","eml":"message/rfc822","js":"text/javascript","ts":"text/plain","py":"text/x-python","swift":"text/x-swift","sh":"text/x-shellscript","sql":"text/plain","toml":"text/plain","ini":"text/plain",
        "docx":"application/vnd.openxmlformats-officedocument.wordprocessingml.document","xlsx":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","pptx":"application/vnd.openxmlformats-officedocument.presentationml.presentation"
    ]
    public static func mimeType(name: String, declared: String? = nil) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if let known = extensions[ext] { return known }
        if let declared = declared?.lowercased().split(separator:";").first.map(String.init), declared.contains("/"), declared != "application/octet-stream" { return declared }
        return "application/octet-stream"
    }
    static func textual(_ type: String) -> Bool {
        type.hasPrefix("text/") || ["application/json","application/xml","application/x-yaml","application/javascript","application/x-javascript","message/rfc822"].contains(type)
    }
    public static func isImage(_ type: String) -> Bool { type.hasPrefix("image/") }

    /// Returns text, pages, preview/thumb data URLs, the method used, a status of
    /// ready / empty / unsupported / failed, and a user-facing message.
    public static func extract(name: String, type declared: String?, data: Data) -> [String:Any] {
        let type = mimeType(name:name,declared:declared)
        var result: [String:Any] = ["type":type,"text":"","pages":0,"method":"none","status":"unsupported","message":"Text extraction is not available for this file type. The file is kept as-is."]
        guard data.count <= maxBytes else { result["status"] = "failed"; result["message"] = "Files larger than 25 MB cannot be imported."; return result }
        do {
            let extracted: Extraction
            if type == "application/pdf" { extracted = try pdf(data) }
            else if isImage(type) { extracted = try image(data) }
            else if type == "text/rtf" { extracted = try rtf(data) }
            else if textual(type) { extracted = Extraction(text:type == "text/html" ? html(decode(data)) : decode(data),pages:1,method:"text") }
            else if type.hasPrefix("application/vnd.openxmlformats-officedocument.") { extracted = try office(data,type:type) }
            else { return result }
            var text = extracted.text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\u{0}",with:"")
            var truncated = false
            if text.count > maxCharacters { text = String(text.prefix(maxCharacters)); truncated = true }
            text = text.trimmingCharacters(in:.whitespacesAndNewlines)
            result["text"] = text; result["pages"] = extracted.pages; result["method"] = extracted.method
            if let preview = extracted.preview { result["preview"] = preview }
            if let thumb = extracted.thumb { result["thumb"] = thumb }
            result["status"] = text.isEmpty ? "empty" : "ready"
            let message: String? = text.isEmpty ? "No readable text was found in this file." : truncated ? "Text was truncated to the first two million characters." : extracted.note
            result["message"] = message ?? NSNull()
        } catch { result["status"] = "failed"; result["message"] = error.localizedDescription }
        return result
    }
    struct Extraction { var text: String; var pages: Int; var method: String; var preview: String? = nil; var thumb: String? = nil; var note: String? = nil }

    // MARK: Plain text, HTML and RTF
    static func decode(_ data: Data) -> String {
        if data.starts(with:[0xEF,0xBB,0xBF]), let text = String(data:data.dropFirst(3),encoding:.utf8) { return text }
        if data.starts(with:[0xFF,0xFE]) || data.starts(with:[0xFE,0xFF]), let text = String(data:data,encoding:.utf16) { return text }
        return String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) ?? ""
    }
    static func entities(_ text: String) -> String {
        var value = text
        for (entity, replacement) in [("&nbsp;"," "),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&apos;","'"),("&#39;","'")] { value = value.replacingOccurrences(of:entity,with:replacement) }
        if let regex = try? NSRegularExpression(pattern:"&#(x[0-9a-fA-F]+|[0-9]+);") {
            let source = value as NSString
            var output = "", last = 0
            for match in regex.matches(in:value,range:NSRange(location:0,length:source.length)) {
                output += source.substring(with:NSRange(location:last,length:match.range.location - last))
                let code = source.substring(with:match.range(at:1))
                let number = code.hasPrefix("x") ? Int(code.dropFirst(),radix:16) : Int(code)
                if let number, let scalar = Unicode.Scalar(number) { output.unicodeScalars.append(scalar) } else { output += " " }
                last = match.range.location + match.range.length
            }
            value = output + source.substring(from:last)
        }
        return value.replacingOccurrences(of:"&amp;",with:"&")
    }
    static func html(_ html: String) -> String {
        var text = html.replacingOccurrences(of:"<!--[\\s\\S]*?-->",with:" ",options:.regularExpression)
        text = text.replacingOccurrences(of:"<(script|style|svg|noscript|template|iframe|object)\\b[^>]*>[\\s\\S]*?</\\1\\s*>",with:" ",options:[.regularExpression,.caseInsensitive])
        text = text.replacingOccurrences(of:"<br\\b[^>]*>|</(?:p|div|li|h[1-6]|tr|section|article|blockquote|pre|td|th)>",with:"\n",options:[.regularExpression,.caseInsensitive])
        text = text.replacingOccurrences(of:"<[^>]*>",with:" ",options:.regularExpression)
        return tidy(entities(text))
    }
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of:"[\\t\\r ]+",with:" ",options:.regularExpression)
            .replacingOccurrences(of:" *\\n *",with:"\n",options:.regularExpression)
            .replacingOccurrences(of:"\\n{3,}",with:"\n\n",options:.regularExpression)
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func rtf(_ data: Data) throws -> Extraction {
        #if canImport(UIKit) || canImport(AppKit)
        let attributed = try NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil)
        return Extraction(text:attributed.string,pages:1,method:"rtf")
        #else
        throw NotebookError.message("RTF reading is unavailable on this platform.")
        #endif
    }

    // MARK: PDF
    static func pdf(_ data: Data) throws -> Extraction {
        guard let document = PDFDocument(data:data) else { throw NotebookError.message("This file could not be read as a PDF.") }
        if document.isLocked { throw NotebookError.message("This PDF is password protected. Remove the password and import it again.") }
        let count = document.pageCount
        guard count > 0 else { throw NotebookError.message("This PDF has no pages.") }
        var parts: [String] = [], characters = 0
        for index in 0..<count {
            let text = tidy(document.page(at:index)?.string ?? "")
            characters += text.count; parts.append(text)
        }
        var method = "pdf", note: String? = nil
        // Scanned PDFs carry images rather than text: recognize it from the page renderings.
        if characters < 40 * count {
            var recognized: [String] = []
            for index in 0..<min(count,recognizedPages) {
                guard let page = document.page(at:index)?.pageRef, let rendering = render(page,maxPixels:recognizePixels) else { recognized.append(parts[index]); continue }
                let text = (try? recognize(rendering)) ?? ""
                recognized.append(text.count > parts[index].count ? text : parts[index])
            }
            if recognized.joined().count > parts.joined().count {
                parts = recognized + parts.dropFirst(recognized.count); method = "pdf+ocr"
                if count > recognizedPages { note = "Text was recognized from the first \(recognizedPages) scanned pages." }
            }
        }
        let text = count == 1 ? parts[0] : parts.enumerated().map { "[Page \($0.offset + 1)]\n" + $0.element }.joined(separator:"\n\n")
        let first = document.page(at:0)?.pageRef
        return Extraction(text:text,pages:count,method:method,preview:first.flatMap { render($0,maxPixels:previewPixels) }.flatMap(jpeg),thumb:first.flatMap { render($0,maxPixels:thumbnailPixels) }.flatMap(jpeg),note:note)
    }
    static func render(_ page: CGPDFPage, maxPixels: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let width = rotated ? box.height : box.width, height = rotated ? box.width : box.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(CGFloat(maxPixels) / max(width,height),4)
        let size = CGSize(width:max(1,(width * scale).rounded()),height:max(1,(height * scale).rounded()))
        guard let context = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1)); context.fill(CGRect(origin:.zero,size:size))
        context.interpolationQuality = .high
        context.concatenate(page.getDrawingTransform(.cropBox,rect:CGRect(origin:.zero,size:size),rotate:0,preserveAspectRatio:true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Images
    static func image(_ data: Data) throws -> Extraction {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), CGImageSourceGetCount(source) > 0 else { throw NotebookError.message("This image could not be read.") }
        func scaled(_ pixels: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:pixels] as CFDictionary)
        }
        guard let recognizable = scaled(recognizePixels) else { throw NotebookError.message("This image could not be decoded.") }
        let text = (try? recognize(recognizable)) ?? ""
        return Extraction(text:text,pages:1,method:"ocr",preview:scaled(previewPixels).flatMap(jpeg),thumb:scaled(thumbnailPixels).flatMap(jpeg))
    }
    static func jpeg(_ image: CGImage) -> String? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,"public.jpeg" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (output as Data).base64EncodedString()
    }
    /// Vision observations arrive unordered; reassemble reading order top-to-bottom, left-to-right.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (text: String, box: CGRect)? in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return (candidate.string, observation.boundingBox)
        }.sorted { a, b in
            let overlap = min(a.box.maxY,b.box.maxY) - max(a.box.minY,b.box.minY)
            if overlap > min(a.box.height,b.box.height) * 0.5 { return a.box.minX < b.box.minX }
            return a.box.midY > b.box.midY
        }
        var output = "", previous: CGRect? = nil
        for line in lines {
            if let previous { output += min(previous.maxY,line.box.maxY) - max(previous.minY,line.box.minY) > min(previous.height,line.box.height) * 0.5 ? "  " : "\n" }
            output += line.text; previous = line.box
        }
        return output
    }

    // MARK: Office Open XML (Word, Excel, PowerPoint)
    static func office(_ data: Data, type: String) throws -> Extraction {
        let archive = try ZipArchive(data:data)
        func xmlText(_ xml: String, breaks: String) -> String {
            var text = xml.replacingOccurrences(of:breaks,with:"\n",options:.regularExpression)
            text = text.replacingOccurrences(of:"<w:tab/>|</w:tc>|</a:tc>",with:"\t",options:.regularExpression)
            text = text.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)
            return tidy(entities(text))
        }
        if type.hasSuffix("wordprocessingml.document") {
            guard let body = archive.text("word/document.xml") else { throw NotebookError.message("This Word document has no readable body.") }
            var text = xmlText(body,breaks:"</w:p>|<w:br[^>]*/>|</w:tr>")
            for part in ["word/footnotes.xml","word/endnotes.xml"] { if let extra = archive.text(part) { let notes = xmlText(extra,breaks:"</w:p>"); if !notes.isEmpty { text += "\n\n" + notes } } }
            return Extraction(text:text,pages:1,method:"office")
        }
        if type.hasSuffix("presentationml.presentation") {
            let slides = archive.names.compactMap { name -> (Int,String)? in
                guard let match = name.range(of:"^ppt/slides/slide([0-9]+)\\.xml$",options:.regularExpression) else { return nil }
                return (Int(name[match].filter(\.isNumber)) ?? 0, name)
            }.sorted { $0.0 < $1.0 }
            let text = slides.enumerated().compactMap { index, slide in archive.text(slide.1).map { "[Slide \(index + 1)]\n" + xmlText($0,breaks:"</a:p>|<a:br[^>]*/>") } }.joined(separator:"\n\n")
            return Extraction(text:text,pages:slides.count,method:"office")
        }
        if type.hasSuffix("spreadsheetml.sheet") {
            var shared: [String] = []
            if let strings = archive.text("xl/sharedStrings.xml") {
                shared = matches(strings,"<si>([\\s\\S]*?)</si>").map { item in entities(matches(item,"<t[^>]*>([\\s\\S]*?)</t>").joined()) }
            }
            let names = archive.text("xl/workbook.xml").map { matches($0,"<sheet [^>]*?name=\"([^\"]*)\"") } ?? []
            let sheets = archive.names.compactMap { name -> (Int,String)? in
                guard let match = name.range(of:"^xl/worksheets/sheet([0-9]+)\\.xml$",options:.regularExpression) else { return nil }
                return (Int(name[match].filter(\.isNumber)) ?? 0, name)
            }.sorted { $0.0 < $1.0 }
            var sections: [String] = []
            for (index, sheet) in sheets.enumerated() {
                guard let xml = archive.text(sheet.1) else { continue }
                let rows = matches(xml,"<row\\b[^>]*>([\\s\\S]*?)</row>").map { row -> String in
                    matches(row,"(<c\\b[^>]*?(?:/>|>[\\s\\S]*?</c>))").map { cell -> String in
                        let kind = matches(cell,"\\bt=\"([^\"]*)\"").first ?? ""
                        if kind == "inlineStr" { return entities(matches(cell,"<t[^>]*>([\\s\\S]*?)</t>").joined()) }
                        guard let value = matches(cell,"<v>([\\s\\S]*?)</v>").first else { return "" }
                        if kind == "s", let number = Int(value), number >= 0, number < shared.count { return shared[number] }
                        return entities(value)
                    }.joined(separator:"\t")
                }.filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty }
                let title = names.count == sheets.count ? names[index] : "Sheet \(index + 1)"
                sections.append("[\(title)]\n" + rows.joined(separator:"\n"))
            }
            return Extraction(text:sections.joined(separator:"\n\n"),pages:sheets.count,method:"office")
        }
        throw NotebookError.message("This Office file type is not supported.")
    }
    static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern:pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in:text,range:NSRange(location:0,length:source.length)).map { source.substring(with:$0.range(at:1)) }
    }
}

/// A minimal reader for stored and deflated zip entries, enough for Office files.
struct ZipArchive {
    struct Entry { let name: String; let method: UInt16; let compressed: Int; let uncompressed: Int; let offset: Int }
    let data: Data
    let entries: [Entry]
    var names: [String] { entries.map(\.name) }
    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var end = bytes.count - 22
        while end >= 0, !(bytes[end] == 0x50 && bytes[end + 1] == 0x4b && bytes[end + 2] == 0x05 && bytes[end + 3] == 0x06) { end -= 1 }
        guard end >= 0 else { throw NotebookError.message("This file is not a valid Office document.") }
        let count = u16(end + 10)
        var position = u32(end + 16), found: [Entry] = []
        for _ in 0..<count {
            guard position + 46 <= bytes.count, u32(position) == 0x02014b50 else { break }
            let nameLength = u16(position + 28), extraLength = u16(position + 30), commentLength = u16(position + 32)
            guard position + 46 + nameLength <= bytes.count else { break }
            let name = String(decoding:bytes[(position + 46)..<(position + 46 + nameLength)],as:UTF8.self)
            found.append(Entry(name:name,method:UInt16(u16(position + 10)),compressed:u32(position + 20),uncompressed:u32(position + 24),offset:u32(position + 42)))
            position += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }
    func contents(_ name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard entry.offset + 30 <= bytes.count, u16(entry.offset) == 0x4b50 else { return nil }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard start + entry.compressed <= bytes.count, entry.uncompressed <= 64 * 1024 * 1024 else { return nil }
        let raw = data.subdata(in:start..<(start + entry.compressed))
        if entry.method == 0 { return raw }
        guard entry.method == 8, entry.uncompressed > 0 else { return nil }
        var output = Data(count:entry.uncompressed)
        let size = output.withUnsafeMutableBytes { destination -> Int in
            raw.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,entry.uncompressed,source.bindMemory(to:UInt8.self).baseAddress!,raw.count,nil,COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { return nil }
        return output.prefix(size)
    }
    func text(_ name: String) -> String? { contents(name).map { String(decoding:$0,as:UTF8.self) } }
}
