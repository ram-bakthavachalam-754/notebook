import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import NotebookCore

/// iCloud status and "Connect iPhone": this Mac shows a QR code, the iPhone
/// scans it, both show the same six digits, and the Mac approves.
struct MacSyncSettings: View {
    @ObservedObject var model: NotebookModel
    @State private var provisioned = false
    @State private var qr: NSImage?
    @State private var pending: [String:Any]?
    @State private var problem: String?
    @State private var polling: Task<Void,Never>?
    var body: some View {
        Form {
            Section {
                LabeledContent("iCloud", value:!provisioned ? "Not set up in this build" : model.connected ? "Connected" : "Not connected")
                Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
                if provisioned && model.connected { Button("Sync Now") { Task { await model.sync() } }.disabled(model.syncing) }
                if !provisioned {
                    Text("This copy of Notebook isn't signed for iCloud, so it keeps your notebook on this Mac only. A build signed with your developer team syncs with your iPhone; see docs/IOS_SYNC.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if provisioned {
                Section("Connect iPhone") {
                    if let pending {
                        Text("“\(pending["name"] as? String ?? "iPhone")” wants to connect. Check that your iPhone shows this number:")
                        Text(pending["confirmation"] as? String ?? "").font(.system(size:30, weight:.medium, design:.monospaced)).tracking(4)
                        HStack { Button("Approve") { approve() }.keyboardShortcut(.defaultAction); Button("Cancel") { cancel() } }
                    } else if let qr {
                        HStack(alignment:.top, spacing:16) {
                            Image(nsImage:qr).interpolation(.none).resizable().frame(width:150, height:150)
                            Text("On your iPhone, open Notebook → Settings → Scan pairing code. Use the same Apple Account on both. The code expires in 10 minutes.").font(.callout)
                        }
                        Button("Cancel") { cancel() }
                    } else {
                        Text("Your iPhone gets a complete copy of this notebook and stays in sync through iCloud.").font(.callout).foregroundStyle(.secondary)
                        Button("Show Pairing Code") { begin() }
                    }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
        .task { provisioned = CloudSync.provisioned(container:await model.cloud.containerID) }
        .onDisappear { if qr != nil || pending != nil { cancel() } }
    }
    private func begin() {
        problem = nil
        Task {
            do {
                let code = try await model.cloud.beginPairing()
                qr = Self.qrImage(code)
                polling = Task {
                    while !Task.isCancelled, pending == nil {
                        try? await Task.sleep(for:.seconds(3))
                        if let request = try? await model.cloud.pendingPairing() { pending = request }
                    }
                }
            } catch { problem = error.localizedDescription }
        }
    }
    private func approve() {
        guard let code = pending?["confirmation"] as? String else { return }
        Task {
            do { try await model.cloud.approvePairing(confirmation:code); reset(); await model.sync() }
            catch { problem = error.localizedDescription }
        }
    }
    private func cancel() { polling?.cancel(); Task { await model.cloud.cancelPairing() }; reset() }
    private func reset() { polling?.cancel(); polling = nil; qr = nil; pending = nil }
    static func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8, y:8)),
              let image = CIContext().createCGImage(output, from:output.extent) else { return nil }
        return NSImage(cgImage:image, size:NSSize(width:output.extent.width, height:output.extent.height))
    }
}
