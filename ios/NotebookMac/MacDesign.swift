import SwiftUI

/// The Mac app's shared look: page titles, cards, stat tiles and small badges,
/// so every section reads as one app.
enum MacStyle {
    static let pagePadding: CGFloat = 32
    static let readableWidth: CGFloat = 860
    static let cardRadius: CGFloat = 14
    static let titleFont = Font.system(size:30, weight:.semibold, design:.serif)
    static let headingFont = Font.system(size:22, weight:.semibold, design:.serif)
}

extension Color {
    /// Gains read green and losses red; nothing (zero, unknown) stays secondary.
    static func gain(_ value: Double) -> Color { value > 0 ? .green : value < 0 ? .red : .secondary }
    /// A quiet fill that sits a step above the window background in light and dark.
    static let cardFill = Color.primary.opacity(0.035)
    static let cardStroke = Color.primary.opacity(0.07)
}

/// A large serif title with an optional line under it.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(alignment:.firstTextBaseline, spacing:16) {
            VStack(alignment:.leading, spacing:6) {
                Text(title).font(MacStyle.titleFont).textSelection(.enabled)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true) }
            }
            Spacer(minLength:0)
            accessory()
        }
    }
}
extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title:title, subtitle:subtitle) { EmptyView() } }
}

/// A rounded surface for grouping related content.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth:.infinity, alignment:.leading)
            .background(Color.cardFill, in:RoundedRectangle(cornerRadius:MacStyle.cardRadius, style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:MacStyle.cardRadius, style:.continuous).strokeBorder(Color.cardStroke))
    }
}
/// A Back link over a page pushed onto a navigation stack, such as a ticker page. The stack's
/// own back button sits in the toolbar above the middle column, where it's easy to miss.
struct BackBarModifier: ViewModifier {
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.safeAreaInset(edge:.top, spacing:0) {
            if isPresented {
                HStack {
                    Button { dismiss() } label: { Label("Back", systemImage:"chevron.left").font(.callout.weight(.medium)) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).keyboardShortcut("[", modifiers:.command).help("Back (⌘[)")
                    Spacer()
                }
                .padding(.horizontal, MacStyle.pagePadding).padding(.vertical, 8).background(.background)
            }
        }
    }
}
extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardModifier(padding:padding)) }
    func backBar() -> some View { modifier(BackBarModifier()) }
    /// A page's content column: padded, readable width, pinned to the leading edge.
    func pageColumn(_ width: CGFloat = MacStyle.readableWidth) -> some View {
        padding(.horizontal, MacStyle.pagePadding).padding(.vertical, 28).frame(maxWidth:width, alignment:.leading).frame(maxWidth:.infinity, alignment:.leading)
    }
}

/// A titled group: a small heading over its content, with an optional trailing control.
struct SectionBlock<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment:.leading, spacing:10) {
            HStack(alignment:.firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength:0)
                trailing()
            }
            content()
        }
    }
}
extension SectionBlock where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.init(title:title, trailing:{ EmptyView() }, content:content) }
}

/// One headline number with a label above and a detail line below.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var tint: Color = .primary
    var body: some View {
        VStack(alignment:.leading, spacing:5) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(value).font(.system(size:22, weight:.semibold, design:.rounded)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2).fixedSize(horizontal:false, vertical:true) }
        }
        .frame(maxWidth:.infinity, alignment:.topLeading)
        .card(padding:14)
    }
}

/// A small tinted capsule for a status or a count.
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14), in:Capsule())
    }
}

/// A rounded square with a letter or symbol, for rows without a picture (a site, a ticker).
struct Monogram: View {
    let text: String
    var tint: Color = .notebookBlue
    var size: CGFloat = 30
    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.system(size:size * 0.46, weight:.semibold, design:.rounded))
            .foregroundStyle(tint)
            .frame(width:size, height:size)
            .background(tint.opacity(0.13), in:RoundedRectangle(cornerRadius:size * 0.28, style:.continuous))
    }
    /// A steady color per name, so the same site or ticker always looks the same.
    static func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan, .mint, .brown]
        return palette[Int(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % UInt32(palette.count))]
    }
}

/// What the right-hand pane shows before anything is chosen.
struct EmptyDetail: View {
    let title: String
    let systemImage: String
    var message: String = ""
    var body: some View {
        ContentUnavailableView { Label(title, systemImage:systemImage) } description: { if !message.isEmpty { Text(message) } }
            .frame(maxWidth:.infinity, maxHeight:.infinity)
    }
}

/// A sheet for adding or editing something: a title, grouped fields, and the
/// buttons in a bar along the bottom, as in the system's own sheets.
struct EditorSheet<Fields: View, Actions: View>: View {
    let title: String
    var width: CGFloat = 440
    var height: CGFloat = 320
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing:0) {
            Text(title).font(.headline).padding(.top, 18).padding(.bottom, 2)
            Form { fields() }.formStyle(.grouped)
            Divider()
            HStack(spacing:10) { actions() }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width:width, height:height)
    }
}
