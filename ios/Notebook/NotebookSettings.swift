import SwiftUI
import AVFoundation

struct NotebookSettings: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.dismiss) var dismiss
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
            .onDisappear { waiting?.cancel() }
        }
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
