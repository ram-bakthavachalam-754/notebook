import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

/// Actions the editor toolbar can send.
enum NoteEditorCommand: Equatable {
    case bold, italic, heading, bulletList, numberedList
    /// A photo saved as its own media record; the note keeps only a marker.
    case insertMedia(id: String, src: String)
    var arguments: [String:String] {
        switch self {
        case .bold: ["name":"bold"]
        case .italic: ["name":"italic"]
        case .heading: ["name":"heading"]
        case .bulletList: ["name":"bulletList"]
        case .numberedList: ["name":"numberedList"]
        case .insertMedia(let id, let src): ["name":"insertMedia", "id":id, "src":src]
        }
    }
}

/// Edits a note's existing HTML in place. Opening a note never rewrites it:
/// the stored HTML is shown as-is (scripts, frames, forms and network access
/// are blocked by the content security policy instead of being removed), and
/// the note is saved only after the person actually changes it. That keeps
/// formatting from older Notebook versions intact.
struct NoteEditor {
    let html: String
    let media: [String:String]
    @Binding var command: NoteEditorCommand?
    /// Off for a note someone shared with you to view only.
    var editable = true
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(coordinator, name:"changed")
        let view = WKWebView(frame:.zero, configuration:config)
        view.navigationDelegate = coordinator
        #if os(macOS)
        view.setValue(false, forKey:"drawsBackground")
        #else
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        #endif
        coordinator.webView = view
        view.loadHTMLString(Self.page(nonce:UUID().uuidString, editable:editable), baseURL:nil)
        return view
    }
    private func update(_ view: WKWebView, _ coordinator: Coordinator) {
        coordinator.parent = self
        if coordinator.loaded && coordinator.media != media {
            coordinator.media = media
            view.callAsyncJavaScript("window.setMedia(media)", arguments:["media":media], in:nil, in:.page) { _ in }
        }
        if let command {
            view.callAsyncJavaScript("window.runCommand(command)", arguments:["command":command.arguments], in:nil, in:.page) { _ in }
            DispatchQueue.main.async { self.command = nil }
        }
    }
    private static func page(nonce: String, editable: Bool) -> String {
        #if os(macOS)
        let font = "15px/1.7 -apple-system", padding = "14px 32px 120px"
        #else
        let font = "17px/1.65 -apple-system", padding = "8px 22px 80px"
        #endif
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; form-action 'none'; frame-src 'none'; connect-src 'none';">
        <style>:root{color-scheme:light dark}body{margin:0;padding:\(padding);font:\(font);color:#171717;overflow-wrap:anywhere}#nb-editor-root{outline:none;min-height:70vh;max-width:760px}p{margin:0 0 .7em}ul,ol{padding-left:1.4em}li{margin:.2em 0}#nb-editor-root>:first-child{margin-top:0}::selection{background:#2f6bff33}img,video{max-width:100%;height:auto;border-radius:10px}h1,h2,h3{font-family:ui-serif,'New York',Charter,Georgia,serif;font-weight:600;letter-spacing:-.01em;margin:1.1em 0 .4em}h1{font-size:1.7em}h2{font-size:1.35em}h3{font-size:1.12em}blockquote{border-left:3px solid #2f6bff;margin-left:0;padding-left:16px;color:#4f4f4c}a{color:#2f6bff}table{border-collapse:collapse;max-width:100%}td,th{border:1px solid #c8c8c4;padding:6px 10px}pre,code{font-family:ui-monospace,Menlo,monospace;font-size:.9em}pre{background:#0000000d;padding:10px 12px;border-radius:8px;overflow-x:auto}@media(prefers-color-scheme:dark){body{color:#ececea}a{color:#5d8bff}blockquote{color:#b4b4b0}pre{background:#ffffff12}td,th{border-color:#3a3a37}}</style></head>
        <body><div id="nb-editor-root" contenteditable="\(editable)" role="textbox" aria-label="Note content" aria-multiline="true"></div>
        <script nonce="\(nonce)">
        const editor=document.getElementById('nb-editor-root');
        // Only pasted HTML is cleaned; a note's own HTML is never altered on open.
        function cleanPaste(html){const doc=new DOMParser().parseFromString(html,'text/html');doc.querySelectorAll('script,style,iframe,object,embed,form,input,button,link,meta,base').forEach(n=>n.remove());doc.querySelectorAll('*').forEach(el=>{for(const a of [...el.attributes]){if(a.name.startsWith('on')||['srcdoc','formaction','contenteditable','id','class','style'].includes(a.name))el.removeAttribute(a.name);if(['src','href','poster'].includes(a.name)&&!(/^(data:(image|video)\\/|https?:|mailto:|#)/i.test(a.value)))el.removeAttribute(a.name);}});return doc.body.innerHTML;}
        window.setMedia=(media)=>{editor.querySelectorAll('[data-media]').forEach(el=>{const data=media[el.dataset.media];if(data)el.src=data;if(el.tagName==='VIDEO')el.controls=true;});};
        window.setContent=(html,media)=>{editor.innerHTML=html;window.setMedia(media);};
        function changed(){const copy=editor.cloneNode(true);copy.querySelectorAll('[data-media]').forEach(el=>el.removeAttribute('src'));window.webkit.messageHandlers.changed.postMessage(copy.innerHTML);}
        editor.addEventListener('input',changed);
        editor.addEventListener('paste',event=>{event.preventDefault();const html=event.clipboardData.getData('text/html');const text=event.clipboardData.getData('text/plain');if(html)document.execCommand('insertHTML',false,cleanPaste(html));else document.execCommand('insertText',false,text);changed();});
        editor.addEventListener('click',e=>{const link=e.target.closest('a');if(link&&!(e.metaKey||e.ctrlKey))e.preventDefault();});
        window.runCommand=(command)=>{editor.focus();const name=command.name;
          if(name==='heading'){const block=document.queryCommandValue('formatBlock').toLowerCase();document.execCommand('formatBlock',false,block==='h2'?'p':'h2');}
          else if(name==='insertMedia'){const img=document.createElement('img');img.setAttribute('data-media',command.id);img.src=command.src;document.execCommand('insertHTML',false,img.outerHTML+'<p><br></p>');}
          else{document.execCommand({bold:'bold',italic:'italic',bulletList:'insertUnorderedList',numberedList:'insertOrderedList'}[name]);}
          changed();};
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: NoteEditor
        weak var webView: WKWebView?
        var loaded = false
        var media: [String:String] = [:]
        init(_ parent: NoteEditor) { self.parent = parent }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.frameInfo.isMainFrame, let html = message.body as? String { parent.onChange(html) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true; media = parent.media
            webView.callAsyncJavaScript("window.setContent(html,media)", arguments:["html":parent.html, "media":parent.media], in:nil, in:.page) { _ in }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme != "about" else { return decisionHandler(.allow) }
            // Command-clicked web links open in the browser; nothing navigates the editor itself.
            if action.navigationType == .linkActivated, ["http","https","mailto"].contains(url.scheme ?? "") {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        }
    }
}

#if os(macOS)
extension NoteEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName:"changed") }
}
#else
extension NoteEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName:"changed") }
}
#endif
