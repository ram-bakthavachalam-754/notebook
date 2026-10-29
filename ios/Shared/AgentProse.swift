import SwiftUI

/// Renders an agent reply from AgentPresentation blocks: headings, lists, code, quotes and tables.
struct AgentProse: View {
    let blocks: [AgentProseBlock]
    private func inline(_ text: String) -> Text {
        if let value = try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace)) { return Text(value) }
        return Text(text)
    }
    var body: some View {
        #if os(macOS)
        AgentProseText(blocks:blocks).frame(maxWidth:.infinity,alignment:.leading)
        #else
        VStack(alignment:.leading,spacing:0) {
            ForEach(blocks) { block in
                switch block.kind {
                case "heading":
                    inline(block.content).font(block.level == 1 ? .system(size:26, weight:.semibold, design:.serif) : block.level == 2 ? .title3.weight(.semibold) : .headline).accessibilityAddTraits(.isHeader).padding(.top,block.id == 0 ? 0 : 14).padding(.bottom,10)
                case "item":
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        Text(block.marker).foregroundStyle(.secondary).monospacedDigit().frame(minWidth:20,alignment:.trailing)
                        inline(block.content).frame(maxWidth:.infinity,alignment:.leading)
                    }.padding(.leading,CGFloat(block.depth)*18).padding(.bottom,10)
                case "code":
                    VStack(alignment:.leading,spacing:8) {
                        if !block.language.isEmpty { Text(block.language).font(.caption2).foregroundStyle(.secondary) }
                        ScrollView(.horizontal) { Text(block.content).font(.callout.monospaced()).fixedSize(horizontal:true,vertical:false) }
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.notebookPaper,in:RoundedRectangle(cornerRadius:10)).padding(.bottom,16)
                case "quote":
                    HStack(spacing:14) { RoundedRectangle(cornerRadius:2).fill(Color.secondary.opacity(0.3)).frame(width:3); inline(block.content).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading) }.fixedSize(horizontal:false,vertical:true).padding(.bottom,16)
                case "rule": Divider().padding(.vertical,16)
                case "table":
                    ScrollView(.horizontal) {
                        VStack(alignment:.leading,spacing:0) {
                            ForEach(Array(block.rows.enumerated()),id:\.offset) { index,row in
                                HStack(alignment:.top,spacing:0) {
                                    ForEach(Array(row.enumerated()),id:\.offset) { _,cell in inline(cell).font(.callout.weight(index == 0 ? .semibold : .regular)).frame(width:160,alignment:.leading).padding(10) }
                                }.background(index == 0 ? Color.notebookPaper : Color.clear)
                                Divider()
                            }
                        }
                    }.padding(.bottom,16)
                default: inline(block.content).frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,16)
                }
            }
        }.font(.body).lineSpacing(4).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        #endif
    }
}

#if os(macOS)
import AppKit

/// The whole reply in one text view, so a selection can run across paragraphs, lists, code and tables.
/// (SwiftUI only selects within a single Text.) Uses TextKit 1 for NSTextBlock and NSTextTable.
struct AgentProseText: NSViewRepresentable {
    let blocks: [AgentProseBlock]
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager:false)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0; view.textContainer?.widthTracksTextView = true
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let text = Self.render(blocks)
        if view.textStorage?.isEqual(to:text) != true { view.textStorage?.setAttributedString(text); view.invalidateIntrinsicContentSize() }
    }
    /// Measures on its own layout stack: SwiftUI asks at several trial widths, and resizing the
    /// view's own container would leave the text laid out at the last trial width, not its frame.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let text = view.textStorage else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480
        let container = NSTextContainer(size:NSSize(width:width, height:.greatestFiniteMagnitude)), layout = NSLayoutManager()
        container.lineFragmentPadding = 0; layout.addTextContainer(container)
        let storage = NSTextStorage(attributedString:text); storage.addLayoutManager(layout)
        layout.ensureLayout(for:container)
        return CGSize(width:width, height:ceil(layout.usedRect(for:container).height))
    }

    private static let paper = NSColor(Color.notebookPaper)
    private static func block(padding: CGFloat = 0, after: CGFloat = 16) -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type:.percentageValueType, for:.width)
        if padding > 0 { block.setWidth(padding, type:.absoluteValueType, for:.padding) }
        block.setWidth(after, type:.absoluteValueType, for:.margin, edge:.maxY)
        return block
    }
    static func inline(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let value = (try? AttributedString(markdown:text, options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in value.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize:font.pointSize * 0.92, weight:.regular) : font
            var traits = runFont.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if traits != runFont.fontDescriptor.symbolicTraits { runFont = NSFont(descriptor:runFont.fontDescriptor.withSymbolicTraits(traits), size:runFont.pointSize) ?? runFont }
            var attributes: [NSAttributedString.Key:Any] = [.font:runFont, .foregroundColor:color]
            if let link = run.link { attributes[.link] = link }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string:String(value[run.range].characters), attributes:attributes))
        }
        return out
    }
    static func render(_ blocks: [AgentProseBlock]) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle:.body)
        let out = NSMutableAttributedString()
        func append(_ piece: NSMutableAttributedString, _ style: NSParagraphStyle) {
            piece.append(NSAttributedString(string:"\n", attributes:[.font:body]))
            piece.addAttribute(.paragraphStyle, value:style, range:NSRange(location:0, length:piece.length))
            out.append(piece)
        }
        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacing = 16
            if index > 0 && blocks[index - 1].kind == "table" { style.paragraphSpacingBefore = 16 }
            switch block.kind {
            case "heading":
                let font: NSFont
                switch block.level {
                case 1: let base = NSFont.systemFont(ofSize:26, weight:.semibold); font = NSFont(descriptor:base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size:26) ?? base
                case 2: font = NSFont.systemFont(ofSize:NSFont.preferredFont(forTextStyle:.title3).pointSize, weight:.semibold)
                default: font = NSFont.preferredFont(forTextStyle:.headline)
                }
                style.paragraphSpacingBefore = index == 0 ? 0 : max(style.paragraphSpacingBefore, 14); style.paragraphSpacing = 10
                append(inline(block.content, font:font), style)
            case "item":
                let indent = CGFloat(block.depth) * 18
                style.firstLineHeadIndent = indent; style.headIndent = indent + 28; style.paragraphSpacing = 10
                style.tabStops = [NSTextTab(textAlignment:.right, location:indent + 20), NSTextTab(textAlignment:.left, location:indent + 28)]
                let piece = NSMutableAttributedString(string:"\t" + block.marker + "\t", attributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:body.pointSize, weight:.regular), .foregroundColor:NSColor.secondaryLabelColor])
                piece.append(inline(block.content, font:body))
                append(piece, style)
            case "code":
                let textBlock = Self.block(padding:14); textBlock.backgroundColor = paper
                style.textBlocks = [textBlock]; style.paragraphSpacing = 0
                let piece = NSMutableAttributedString()
                if !block.language.isEmpty { piece.append(NSAttributedString(string:block.language + "\n", attributes:[.font:NSFont.preferredFont(forTextStyle:.caption2), .foregroundColor:NSColor.secondaryLabelColor])) }
                piece.append(NSAttributedString(string:block.content, attributes:[.font:NSFont.monospacedSystemFont(ofSize:NSFont.preferredFont(forTextStyle:.callout).pointSize, weight:.regular), .foregroundColor:NSColor.labelColor]))
                append(piece, style)
            case "quote":
                let textBlock = Self.block()
                textBlock.setWidth(3, type:.absoluteValueType, for:.border, edge:.minX); textBlock.setBorderColor(NSColor.secondaryLabelColor.withAlphaComponent(0.3), for:.minX)
                textBlock.setWidth(14, type:.absoluteValueType, for:.padding, edge:.minX)
                style.textBlocks = [textBlock]; style.paragraphSpacing = 0
                append(inline(block.content, font:body, color:.secondaryLabelColor), style)
            case "rule":
                let textBlock = Self.block()
                textBlock.setWidth(16, type:.absoluteValueType, for:.margin, edge:.minY)
                textBlock.setWidth(1, type:.absoluteValueType, for:.border, edge:.maxY); textBlock.setBorderColor(.separatorColor, for:.maxY)
                style.textBlocks = [textBlock]; style.paragraphSpacing = 0
                append(NSMutableAttributedString(string:"", attributes:[.font:NSFont.systemFont(ofSize:1)]), style)
            case "table":
                let rows = block.rows, table = NSTextTable()
                table.numberOfColumns = max(1, rows.map(\.count).max() ?? 1)
                for (rowIndex, row) in rows.enumerated() {
                    for (column, cell) in row.enumerated() {
                        let cellBlock = NSTextTableBlock(table:table, startingRow:rowIndex, rowSpan:1, startingColumn:column, columnSpan:1)
                        cellBlock.setValue(160, type:.absoluteValueType, for:.width)
                        cellBlock.setWidth(10, type:.absoluteValueType, for:.padding)
                        cellBlock.setWidth(1, type:.absoluteValueType, for:.border, edge:.maxY); cellBlock.setBorderColor(.separatorColor, for:.maxY)
                        if rowIndex == 0 { cellBlock.backgroundColor = paper }
                        let cellStyle = NSMutableParagraphStyle(); cellStyle.lineSpacing = 4; cellStyle.textBlocks = [cellBlock]
                        let font = NSFont.systemFont(ofSize:NSFont.preferredFont(forTextStyle:.callout).pointSize, weight:rowIndex == 0 ? .semibold : .regular)
                        append(inline(cell, font:font), cellStyle)
                    }
                }
            default:
                append(inline(block.content, font:body), style)
            }
        }
        if out.string.hasSuffix("\n") { out.deleteCharacters(in:NSRange(location:out.length - 1, length:1)) }
        return out
    }
}
#endif
