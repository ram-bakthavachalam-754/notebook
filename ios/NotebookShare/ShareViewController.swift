import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Notebook" in the share sheet: saves the shared web page to Links.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let card = UIHostingController(rootView:ShareCard(load:{ [weak self] in await self?.sharedPage() }, finish:{ [weak self] in self?.extensionContext?.completeRequest(returningItems:nil) }))
        addChild(card); view.addSubview(card.view); card.view.frame = view.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; card.view.backgroundColor = .clear
        card.didMove(toParent:self)
    }
    /// The first web address among the shared items, and the page title Safari passes along.
    private func sharedPage() async -> (url: URL, title: String)? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            let title = item.attributedContentText?.string ?? ""
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier:UTType.url.identifier) as? URL, ["http","https"].contains(url.scheme?.lowercased() ?? "") {
                    return (url, title)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier:UTType.plainText.identifier) as? String,
                   let url = Self.firstLink(in:text) { return (url, title) }
            }
        }
        return nil
    }
    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in:text, range:NSRange(text.startIndex..., in:text)).compactMap(\.url).first { ["http","https"].contains($0.scheme?.lowercased() ?? "") }
    }
}

private struct ShareCard: View {
    let load: () async -> (url: URL, title: String)?
    let finish: () -> Void
    @State private var page: (url: URL, title: String)?
    @State private var loaded = false
    @State private var note = ""
    @State private var problem: String?
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                if let page {
                    Section {
                        VStack(alignment:.leading, spacing:4) {
                            Text(page.title.isEmpty ? (page.url.host() ?? page.url.absoluteString) : page.title).font(.headline).lineLimit(2)
                            Text(page.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        TextField("Add a note (optional)", text:$note, axis:.vertical).lineLimit(1...4)
                    } footer: { Text("Saved to Unsorted in Links. Notebook adds it the next time you open the app.") }
                } else if loaded {
                    Text("There's no web page to save here.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(saved ? "Saved" : "Save to Links").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel", action:finish) }
                ToolbarItem(placement:.confirmationAction) { Button("Save", action:save).disabled(page == nil || saved) }
            }
        }
        .task { page = await load(); loaded = true }
    }
    private func save() {
        guard let page else { return }
        do {
            try LinkInbox.save(.init(url:page.url.absoluteString, title:page.title, note:note.trimmingCharacters(in:.whitespacesAndNewlines), savedAt:Date()))
            saved = true
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.5, execute:finish)
        } catch {
            problem = "Saving from other apps isn't set up in this build of Notebook."
        }
    }
}
