import SwiftUI
import AVFoundation
import WebKit

struct NotebookSettings: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject private var robinhood: RobinhoodLink
    @Environment(\.dismiss) var dismiss
    init(model: NotebookModel) { self.model = model; robinhood = model.robinhood }
    private struct SignInPage: Identifiable { let url: URL; var id: String { url.absoluteString } }
    @State private var signIn: SignInPage?
    @State private var code = ""
    @State private var confirmation: String?
    @State private var scanning = false
    @State private var busy = false
    @State private var pairingError: String?
    @State private var waiting: Task<Void,Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment:.leading,spacing:10) {
                        Image(systemName:"laptopcomputer.and.iphone").font(.system(size:36,weight:.light)).foregroundStyle(Color.notebookBlue)
                        Text("Your notebook, together.").font(.custom("Charter",size:27))
                        Text("A complete copy on each device. Write anywhere, even offline.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical,12)
                    LabeledContent("iCloud",value:model.connected ? "Connected" : "Not connected")
                    Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
                    if model.connected { Button("Sync now") { Task { await model.sync() } }.disabled(model.syncing) }
                }
                Section(model.connected ? "Pair again" : "Connect to Mac") {
                        Text("On your Mac, click iCloud or Connect iPhone → Generate new QR code. Use the same Apple Account on both devices.").font(.subheadline)
                        if model.connected {
                            Text("Scan a fresh code from the same Mac notebook. Your notes and pending changes stay on this device. Pairing again does not reset an iCloud cooldown.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { scanning = true } label: { Label("Scan pairing code",systemImage:"qrcode.viewfinder") }.disabled(busy)
                        TextField("Or paste a pairing code",text:$code,axis:.vertical).font(.caption).textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...3)
                        Button(busy ? "Waiting for your Mac…" : "Connect") { connect() }.disabled(code.isEmpty || busy)
                        if let confirmation {
                            Text(confirmation).font(.system(size:34,weight:.medium,design:.monospaced)).tracking(5).frame(maxWidth:.infinity)
                            Text("Confirm this same number on your Mac, then approve this iPhone.").font(.subheadline)
                        }
                        if let pairingError { Text(pairingError).font(.caption).foregroundStyle(.red) }
                    }
                Section {
                    Toggle("Require Face ID or passcode",isOn:Binding(get:{ model.lockEnabled },set:{ enabled in Task { await model.setProtection(enabled) } }))
                } header: { Text("Privacy") } footer: { Text("Uses this device’s authentication. Sync payloads are encrypted before upload; keys stay in the device Keychain. Keep an authorized device available to pair a replacement.") }
                Section {
                    Text("Notebook keeps both versions when the same entry is changed independently. A copy icon identifies entries that need review.").font(.caption).foregroundStyle(.secondary)
                }
                if model.unlocked && !model.agent.kidMode {
                    Section {
                        NavigationLink { AgentSettingsView(agent:model.agent).scrollContentBackground(.hidden).background(Color.notebookPaper) } label: {
                            AgentSettingsRow(icon:"sparkles", tint:.purple, title:"AI Agent", value:model.agent.config["model"] ?? "")
                        }
                        .accessibilityIdentifier("settings-ai-agent")
                    } footer: { Text("The model the agent uses, and how it searches the web.") }
                }
                if model.unlocked && !model.agent.kidMode {
                    Section {
                        LabeledContent("Status") {
                            if robinhood.connecting { HStack(spacing:6) { ProgressView().controlSize(.small); Text("Finish signing in…") } }
                            else { Text(robinhood.connected ? "Connected, read-only" : "Not connected").foregroundStyle(robinhood.connected ? .primary : .secondary) }
                        }
                        if let error = robinhood.error { Text(error).font(.caption).foregroundStyle(.red) }
                        if robinhood.connected { Button("Disconnect") { robinhood.disconnect() } }
                        else { Button("Connect Robinhood…") { connectRobinhood() }.disabled(robinhood.connecting) }
                    } header: { Text("Robinhood") } footer: {
                        Text("Real-time stock and option quotes in Finance. You sign in with Robinhood here in Safari; Notebook never sees your password, can't place orders, and keeps its access in this iPhone's keychain. Without it, quotes come from Yahoo Finance.")
                    }
                }
                if model.unlocked {
                    Section {
                        NavigationLink { FamilySettings(family:model.family, agent:model.agent).scrollContentBackground(.hidden).background(Color.notebookPaper) } label: { Label("Family", systemImage:"person.2") }
                        NavigationLink { SharingSettings(sharing:model.sharing).scrollContentBackground(.hidden).background(Color.notebookPaper) } label: { Label("Sharing", systemImage:"person.crop.circle.badge.plus") }
                    } footer: { Text(model.agent.kidMode || model.agent.enrollment != nil ? "A parent manages this device." : "Choose which apps your children get and what Ask will talk about.") }
                }
            }
            .scrollContentBackground(.hidden).background(Color.notebookPaper)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented:$scanning) { PairingScanner { scanned in code = scanned; scanning = false; connect() } }
            .sheet(item:$signIn, onDismiss:{ if robinhood.connecting { robinhood.cancelSignIn() } }) { page in
                NavigationStack {
                    SignInWebView(url:page.url) { robinhood.receivedReply($0) }.ignoresSafeArea(edges:.bottom)
                        .navigationTitle("Robinhood").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { signIn = nil } } }
                }
            }
            .onChange(of:robinhood.connecting) { _, connecting in if !connecting { signIn = nil } }
            .onDisappear { waiting?.cancel() }
        }
    }
    /// Robinhood's sign-in page opens in a sheet that presents itself as a
    /// desktop browser, since the page turns phones away. The sheet hands the
    /// reply to Notebook itself, before the loopback address is ever loaded.
    func connectRobinhood() {
        robinhood.openURL = { url in signIn = SignInPage(url:url) }
        Task { await robinhood.connect() }
    }
    func connect() {
        guard !busy else { return }
        busy = true; pairingError = nil
        waiting = Task {
            defer { busy = false }
            do {
                confirmation = try await model.cloud.requestPairing(code:code.trimmingCharacters(in:.whitespacesAndNewlines),name:UIDevice.current.name)
                code = "" // Do not retain the QR secret in the text field.
                while !Task.isCancelled {
                    try await Task.sleep(for:.seconds(3))
                    if try await model.cloud.finishPairing() { model.reload(); await model.sync(); confirmation = nil; break }
                }
            } catch is CancellationError { }
            catch { pairingError = error.localizedDescription }
        }
    }
}
/// A web page shown as a desktop browser would show it. Navigations to the
/// sign-in reply address go to `onReply` instead of being loaded.
struct SignInWebView: UIViewRepresentable {
    let url: URL
    /// Returns true when the URL was the reply, which closes the page's job.
    let onReply: (URL) -> Bool
    static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
    func makeCoordinator() -> Coordinator { Coordinator(onReply:onReply) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame:.zero, configuration:configuration)
        view.customUserAgent = Self.desktopAgent
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.load(URLRequest(url:url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onReply: (URL) -> Bool
        init(onReply: @escaping (URL) -> Bool) { self.onReply = onReply }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, onReply(url) { decisionHandler(.cancel) } else { decisionHandler(.allow) }
        }
        /// Links that want a new window open in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
    }
}
struct PairingScanner: UIViewControllerRepresentable {
    var prefix = "notebook://pair/"
    var prompt = "Scan the code shown in Notebook on your Mac"
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(prefix:prefix, prompt:prompt, onCode:onCode) }
    func updateUIViewController(_ controller: ScannerController,context: Context) { }
    static func dismantleUIViewController(_ controller: ScannerController,coordinator: ()) { controller.stop() }
}
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label:"notebook.camera")
    let onCode: (String) -> Void
    let prefix: String, prompt: String
    var preview: AVCaptureVideoPreviewLayer?
    var complete = false
    init(prefix: String, prompt: String, onCode: @escaping (String) -> Void) { self.prefix = prefix; self.prompt = prompt; self.onCode = onCode; super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let label = UILabel(); label.text = prompt; label.textColor = .white; label.textAlignment = .center; label.numberOfLines = 2; label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:30),label.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-30),label.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-30)])
        AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
            guard let self else { return }
            if allowed { self.queue.async { self.configure() } }
            else { DispatchQueue.main.async { label.text = "Camera access is off. Enable it in Settings, or paste the code instead." } }
        }
    }
    func configure() {
        guard let device = AVCaptureDevice.default(for:.video), let input = try? AVCaptureDeviceInput(device:device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }; session.addOutput(output)
        output.setMetadataObjectsDelegate(self,queue:.main); output.metadataObjectTypes = [.qr]
        DispatchQueue.main.async {
            let layer = AVCaptureVideoPreviewLayer(session:self.session); layer.videoGravity = .resizeAspectFill; layer.frame = self.view.bounds
            self.preview = layer; self.view.layer.insertSublayer(layer,at:0)
        }
        session.startRunning()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { self.session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput,didOutput metadataObjects: [AVMetadataObject],from connection: AVCaptureConnection) {
        guard !complete, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code.hasPrefix(prefix) else { return }
        complete = true; stop(); onCode(code)
    }
}
