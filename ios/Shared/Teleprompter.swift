import SwiftUI
import NotebookCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A note as a script to read on camera: its text, one line per paragraph or
/// list item, as it was when the teleprompter started. Later edits don't follow.
struct TeleprompterScript: Equatable {
    let title: String
    let text: String
    init(title: String, html: String) {
        self.title = title
        let body = DocumentText.plainText(html:html)
        text = body.isEmpty ? "This note has no text yet." : body
    }
}

/// White text on black that scrolls up past a reading mark near the top edge,
/// so the eyes stay close to the camera. Tap or space plays and pauses, drag
/// scrubs, the sliders set the pace and the size. Mirrored writing is for a
/// glass beam-splitter rig.
struct TeleprompterView: View {
    let script: TeleprompterScript
    let onDone: () -> Void
    /// Points per second.
    @AppStorage("teleprompterSpeed") private var speed = 40.0
    @AppStorage("teleprompterSize") private var size = 34.0
    @AppStorage("teleprompterMirror") private var mirrored = false
    @State private var playing = false
    @State private var offset: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var dragStart: CGFloat?
    #if os(macOS)
    private let sidePadding: CGFloat = 28
    #else
    private let sidePadding: CGFloat = 20
    #endif

    var body: some View {
        VStack(spacing:0) {
            #if os(macOS)
            Capsule().fill(.white.opacity(0.25)).frame(width:36, height:5).padding(.top, 6).padding(.bottom, 2)
            #endif
            GeometryReader { geo in
                // Where the eyes rest: near the top of the panel, just under the camera.
                let lead = max(10, geo.size.height * 0.2)
                ZStack(alignment:.top) {
                    Text(script.text)
                        .font(.system(size:size, weight:.medium, design:.rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(size * 0.25)
                        .frame(width:max(1, geo.size.width - sidePadding * 2))
                        .background(GeometryReader { Color.clear.preference(key:TextHeightKey.self, value:$0.size.height) })
                        .scaleEffect(x:mirrored ? -1 : 1)
                        .offset(y:lead - offset)
                        .padding(.horizontal, sidePadding)
                        .accessibilityLabel(script.title)
                        .accessibilityValue(script.text)
                    RoundedRectangle(cornerRadius:2).fill(Color.accentColor).frame(width:4, height:size * 1.3)
                        .frame(maxWidth:.infinity, alignment:.leading).padding(.leading, 10).offset(y:lead)
                        .accessibilityHidden(true)
                    LinearGradient(colors:[.black, .black.opacity(0)], startPoint:.top, endPoint:.bottom).frame(height:lead * 0.7).allowsHitTesting(false)
                    VStack(spacing:0) { Spacer(minLength:0); LinearGradient(colors:[.black.opacity(0), .black], startPoint:.top, endPoint:.bottom).frame(height:min(50, geo.size.height / 4)) }.allowsHitTesting(false)
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { playing.toggle() }
                .gesture(DragGesture(minimumDistance:4).onChanged { value in
                    if dragStart == nil { dragStart = offset; playing = false }
                    offset = clamp((dragStart ?? 0) - value.translation.height)
                }.onEnded { _ in dragStart = nil })
                .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
            }
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .task(id:playing) { await advance() }
    }

    private var end: CGFloat { max(0, textHeight) }
    private func clamp(_ value: CGFloat) -> CGFloat { min(max(0, value), end) }
    /// Moves the script while playing; stops at the end.
    private func advance() async {
        guard playing else { return }
        // A finished script starts over when played again.
        if offset >= end && end > 0 { offset = 0 }
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for:.milliseconds(16))
            guard !Task.isCancelled else { return }
            let now = ContinuousClock.now
            let elapsed = now - last; last = now
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            offset = clamp(offset + speed * seconds)
            if offset >= end { playing = false; return }
        }
    }

    private var transport: some View {
        HStack(spacing:14) {
            Button { playing = false; offset = 0 } label: { Image(systemName:"backward.end.fill") }.help("Start over").accessibilityLabel("Start over")
            Button { playing.toggle() } label: { Image(systemName:playing ? "pause.fill" : "play.fill").frame(width:18) }
                .keyboardShortcut(.space, modifiers:[]).help(playing ? "Pause (space)" : "Play (space)").accessibilityLabel(playing ? "Pause" : "Play")
        }
    }
    private var sliders: some View {
        HStack(spacing:14) {
            HStack(spacing:6) {
                Image(systemName:"tortoise").font(.caption)
                Slider(value:$speed, in:10...120).frame(minWidth:80, maxWidth:140).accessibilityLabel("Speed")
                Image(systemName:"hare").font(.caption)
            }.help("Speed")
            HStack(spacing:6) {
                Image(systemName:"textformat.size.smaller").font(.caption)
                Slider(value:$size, in:20...72).frame(minWidth:70, maxWidth:120).accessibilityLabel("Text size")
                Image(systemName:"textformat.size.larger").font(.caption)
            }.help("Text size")
        }
    }
    private var extras: some View {
        HStack(spacing:14) {
            Toggle(isOn:$mirrored) { Image(systemName:"arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .toggleStyle(.button).help("Mirror the text for a glass teleprompter").accessibilityLabel("Mirror")
            Button("Done", action:onDone).keyboardShortcut(.cancelAction).help("Close and bring Notebook back (esc)")
        }
    }
    @ViewBuilder private var controls: some View {
        #if os(macOS)
        HStack(spacing:18) { transport; sliders; Spacer(minLength:8); extras }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(.white).tint(.white)
            .controlSize(.small)
        #else
        VStack(spacing:12) {
            sliders
            HStack { transport.font(.title2); Spacer(); extras }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .foregroundStyle(.white).tint(.white)
        #endif
    }
}

private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

#if os(macOS)
/// The teleprompter window on the Mac: a borderless panel parked at the top
/// middle of the screen, just under the camera, floating over every app and
/// space so it stays up during a call or a recording. Starting it puts
/// Notebook's own windows away; Done, Escape or a click on the Dock icon
/// brings them back.
@MainActor final class MacTeleprompter {
    static let shared = MacTeleprompter()
    private var panel: NSPanel?
    private var hidden: [NSWindow] = []
    var running: Bool { panel != nil }

    func start(title: String, html: String) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let script = TeleprompterScript(title:title, html:html)
        if panel != nil { close() }
        hidden = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        hidden.forEach { $0.orderOut(nil) }
        let panel = TeleprompterPanel(contentRect:Self.frame(on:screen), styleMask:[.borderless, .nonactivatingPanel, .resizable], backing:.buffered, defer:false)
        panel.title = "Teleprompter"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width:420, height:150)
        panel.appearance = NSAppearance(named:.darkAqua)
        let root = TeleprompterView(script:script) { [weak self] in self?.stop() }
            .clipShape(RoundedRectangle(cornerRadius:18, style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:18, style:.continuous).strokeBorder(.white.opacity(0.12)))
        panel.contentView = NSHostingView(rootView:root)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }
    /// Closes the panel and brings Notebook back. Returns false when nothing was running.
    @discardableResult func stop() -> Bool {
        guard panel != nil else { return false }
        close()
        for window in hidden { window.makeKeyAndOrderFront(nil) }
        hidden = []
        NSApp.activate(ignoringOtherApps:true)
        return true
    }
    private func close() {
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
    }
    /// Wide and short, centered under the menu bar on the screen Notebook is on.
    private static func frame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x:0, y:0, width:1440, height:900)
        let width = min(960, max(420, visible.width * 0.62)), height: CGFloat = 250
        return NSRect(x:visible.midX - width / 2, y:visible.maxY - height - 6, width:width, height:height)
    }
}
/// Borderless panels take keys (space, escape) only when they say so.
final class TeleprompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
#else
/// Full screen on iPhone and iPad: the text sits at the top, under the front camera.
struct TeleprompterScreen: View {
    let script: TeleprompterScript
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TeleprompterView(script:script) { dismiss() }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
#endif
