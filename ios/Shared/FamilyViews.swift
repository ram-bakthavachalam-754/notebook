import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import NotebookCore

/// Settings → Family. On a parent's device: each child's profile, edited as
/// a draft and published as signed rules. On a child's device: joining the
/// family, then installing the rules the parent publishes.
struct FamilySettings: View {
    @ObservedObject var family: FamilyModel
    @ObservedObject var agent: AgentModel
    @State private var adding = false
    @State private var name = ""
    @State private var age = 9
    @State private var editing: ChildProfile?
    @State private var joinCode = ""
    @State private var joined: String?
    @State private var scanning = false
    @State private var installing = false
    @State private var installResult: String?
    var body: some View {
        Group {
            if agent.kidMode || agent.enrollment != nil { managed } else { parent }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("Family")
        .sheet(isPresented:$scanning) { PairingScanner(prefix:"notebook://family/", prompt:"Scan the family code on your parent's device") { code in scanning = false; join(code) } }
        #endif
        .fileImporter(isPresented:$installing, allowedContentTypes:[.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { try agent.installPolicy(Data(contentsOf:url)); installResult = agent.kidMode ? "Installed." : "Notebook works as an ordinary notebook again." } catch { installResult = error.localizedDescription }
        }
        .alert("Joined", isPresented:Binding(get:{ joined != nil }, set:{ if !$0 { joined = nil } })) { } message: {
            Text("Check that your parent's screen shows \(joined ?? ""). Then install the rules file your parent publishes.")
        }
    }
    /// A device a parent manages shows nothing about the rules themselves.
    private var managed: some View {
        Form {
            Section {
                Text("A parent manages this device.")
                Button("Install Rules File…") { installing = true }
            } footer: { Text(installResult ?? "Your parent publishes a rules file from their Family settings. Install it here when they give it to you.") }
        }
    }
    private func join(_ code: String) {
        do { joined = try agent.joinFamily(code); joinCode = "" } catch { installResult = error.localizedDescription }
    }
    private var parent: some View {
        Form {
            Section {
                if family.children.isEmpty {
                    Text("Add a child to choose which apps they get and what Ask will talk about. Your partner uses Notebook on their own and doesn't need to be added.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(family.children) { child in
                    HStack {
                        VStack(alignment:.leading, spacing:2) {
                            Text(child.name).font(.headline)
                            Text(status(child)).font(.caption).foregroundStyle(family.unpublished(child) > 0 ? .orange : .secondary)
                            if let delivery = family.delivery[child.id] { Text(delivery).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Edit…") { editing = child }
                    }
                }
                Button("Add a Child…") { name = ""; age = 9; adding = true }
            } footer: {
                Text("Profiles are saved in your notebook and sync between your devices. You manage settings only; a child's notes, journal and questions stay in their own iCloud.").font(.caption)
            }
            Section {
                #if os(iOS)
                Button("Scan Family Code…") { scanning = true }
                #endif
                HStack {
                    TextField("Paste a family code", text:$joinCode).autocorrectionDisabled()
                    Button("Join") { join(joinCode) }.disabled(joinCode.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                #if DEBUG
                Button("Install Unsigned Rules File… (testing)") { installing = true }
                #endif
            } header: { Text("Is this your child's device?") } footer: { Text(installResult ?? "Join with the code from Add a Device… in the child's profile on your device. Afterwards this device accepts only rules you sign.") }
        }
        .onAppear { family.reload() }
        .sheet(isPresented:$adding) {
            #if os(macOS)
            Form {
                Text("Add a child").font(.headline)
                addFields
                HStack { Spacer(); Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction); Button("Add", action:add).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in:.whitespaces).isEmpty) }
            }
            .padding(20).frame(width:380)
            #else
            NavigationStack {
                Form { addFields }
                    .navigationTitle("Add a Child").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement:.cancellationAction) { Button("Cancel") { adding = false } }
                        ToolbarItem(placement:.confirmationAction) { Button("Add", action:add).disabled(name.trimmingCharacters(in:.whitespaces).isEmpty) }
                    }
            }
            .presentationDetents([.medium])
            #endif
        }
        .sheet(item:$editing) { ChildEditor(family:family, profile:$0) }
        .alert("Family", isPresented:Binding(get:{ family.error != nil }, set:{ if !$0 { family.error = nil } })) { } message: { Text(family.error ?? "") }
    }
    @ViewBuilder private var addFields: some View {
        TextField("Name", text:$name)
        Stepper("Age: \(age)", value:$age, in:4...17)
        Text("Starting rules for \(age < 10 ? "under 10" : age < 14 ? "10–13" : "teens"). You can change everything next.").font(.caption).foregroundStyle(.secondary)
    }
    private func add() {
        guard let child = family.add(name:name, age:age) else { return }
        adding = false
        // A second sheet can't open while the first is still closing on iPhone.
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.4) { editing = child }
    }
    private func status(_ child: ChildProfile) -> String {
        let changes = family.unpublished(child)
        if child.version == 0 { return "Age \(child.age) · Not published yet" }
        return "Age \(child.age) · " + (changes > 0 ? "\(changes) unpublished change\(changes == 1 ? "" : "s")" : "Published · v\(child.version)")
    }
}

private struct RulesFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

/// One child's settings, in the same order as the design: apps, topics, how
/// Ask answers, your rules, the AI connection, and tools and time.
struct ChildEditor: View {
    @ObservedObject var family: FamilyModel
    @State var profile: ChildProfile
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "apps"
    @State private var newRule = ""
    @State private var newEmail = ""
    @State private var exportFile: RulesFile?
    @State private var exportName = ""
    @State private var confirmDelete = false
    @State private var confirmRelease = false
    @State private var enrolling: (code: String, confirmation: String)?
    private let tabs = [("apps","Apps"), ("topics","Topics"), ("ask","Ask"), ("rules","Rules"), ("connection","Connection"), ("time","Tools & Time")]
    var body: some View { attachDialogs(layout) }
    @ViewBuilder private var layout: some View {
        #if os(macOS)
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading) {
                    Text(profile.name).font(.system(size:24, weight:.semibold, design:.serif))
                    Text("Age \(profile.age)").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection:$tab) { ForEach(tabs, id:\.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(20)
            Divider()
            Form { content(tab) }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Remove Child…", role:.destructive) { confirmDelete = true }
                if profile.version > 0 { Button("Release Devices…") { confirmRelease = true } }
                Button("Add a Device…", action:enroll)
                Spacer()
                Button("Done") { family.save(profile); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Publish to \(profile.name)…") { publish() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width:680, height:600)
        #else
        // On iPhone every group is on one page, in the same order as the Mac tabs.
        NavigationStack {
            Form {
                ForEach(tabs, id:\.0) { content($0.0) }
                Section {
                    Button("Add a Device…", action:enroll)
                    Button("Publish to \(profile.name)…") { publish() }
                    if profile.version > 0 { Button("Release Devices…") { confirmRelease = true } }
                    Button("Remove Child…", role:.destructive) { confirmDelete = true }
                } footer: { Text(status) }
            }
            .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) { Button("Done") { family.save(profile); dismiss() } }
                ToolbarItem(placement:.primaryAction) { Button("Publish") { publish() } }
            }
        }
        #endif
    }
    private var status: String {
        let changes = family.unpublished(profile)
        if profile.version == 0 { return "Not published yet. Publishing saves a rules file to install on \(profile.name)'s device." }
        return changes > 0 ? "\(changes) unpublished change\(changes == 1 ? "" : "s") since v\(profile.version)." : "Published · v\(profile.version)"
    }
    private func enroll() {
        family.save(profile)
        do { enrolling = try family.enrollment(profile); refresh() } catch { family.error = error.localizedDescription }
    }
    private func attachDialogs<V: View>(_ view: V) -> some View {
        view
        .sheet(isPresented:Binding(get:{ enrolling != nil }, set:{ if !$0 { enrolling = nil } })) {
            if let enrolling { EnrollmentSheet(name:profile.name, code:enrolling.code, confirmation:enrolling.confirmation) }
        }
        .alert("Family", isPresented:Binding(get:{ family.error != nil }, set:{ if !$0 { family.error = nil } })) { } message: { Text(family.error ?? "") }
        .fileExporter(isPresented:Binding(get:{ exportFile != nil }, set:{ if !$0 { exportFile = nil } }), document:exportFile, contentType:.json, defaultFilename:exportName) { _ in exportFile = nil }
        .confirmationDialog("Remove \(profile.name)?", isPresented:$confirmDelete) {
            Button("Remove", role:.destructive) { family.delete(profile); dismiss() }
        } message: { Text("Their devices keep the last rules you published until you release them. Release them first to turn kid mode off.") }
        .confirmationDialog("Release \(profile.name)'s devices from kid mode?", isPresented:$confirmRelease) {
            Button("Save Release File…") { do { family.save(profile); exportName = "\(profile.name) release.json"; exportFile = RulesFile(data:try family.release(profile)); refresh() } catch { family.error = error.localizedDescription } }
        } message: { Text("Install the file on each of their devices. Notebook then works as an ordinary notebook there.") }
    }
    @ViewBuilder private func content(_ tab: String) -> some View {
        switch tab {
        case "apps":
            Section("Apps \(profile.name) can open") {
                appToggle("Notes", "notes"); appToggle("Journal", "journal"); appToggle("Ask", "agent"); appToggle("Money", "money"); appToggle("Links", "links"); appToggle("Documents", "documents")
                Text("Money is savings goals and the allowance you set. Finance isn't available to children: it tracks investments. Turning an app off hides it and never deletes anything.").font(.caption).foregroundStyle(.secondary)
            }
            if appOn("notes") {
                Section("Notes") {
                    Toggle("Templates (I wonder, Reading log, Big idea, Checklist)", isOn:Binding(get:{ appValue("notes", "templates") as? Bool ?? true }, set:{ setApp("notes", "templates", $0) }))
                }
            }
            if appOn("journal") {
                Section {
                    Toggle("Evening reminder", isOn:Binding(get:{ appValue("journal", "reminder") is String }, set:{ setApp("journal", "reminder", $0 ? "19:30" : NSNull()) }))
                    if let reminder = appValue("journal", "reminder") as? String {
                        HStack {
                            Text("At")
                            TextField("19:30", text:Binding(get:{ reminder }, set:{ setApp("journal", "reminder", $0) })).frame(width:70)
                            Spacer()
                            Text("24-hour").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Journal") } footer: { Text("The journal stays private: you can't read it.") }
            }
            if appOn("money") {
                Section("Money") {
                    Stepper("Weekly allowance: \(KidApps.money(allowance))", value:Binding(get:{ allowance }, set:{ setApp("money", "allowance", $0) }), in:0...100, step:1)
                }
            }
            Section {
                Picker("Who \(profile.name) can share with", selection:Binding(get:{ sharing("mode") as? String ?? "family" }, set:{ setSharing("mode", $0) })) {
                    Text("Nobody").tag("off"); Text("Family only").tag("family"); Text("Anyone on Notebook").tag("anyone")
                }
                if sharing("mode") as? String ?? "family" == "family" {
                    let emails = sharing("family") as? [String] ?? []
                    ForEach(emails, id:\.self) { email in
                        HStack { Text(email); Spacer(); Button { setSharing("family", emails.filter { $0 != email }) } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless) }
                    }
                    HStack {
                        TextField("A family member's Apple Account email", text:$newEmail).onSubmit(addEmail)
                        Button("Add", action:addEmail).disabled(!newEmail.contains("@") || emails.count >= 20)
                    }
                }
            } header: { Text("Sharing") } footer: { Text("Notes and links collections only; children never share Finance. Family only means the Apple Accounts listed here, for sharing and for accepting.") }
            Section("Photos and files in Ask") {
                toggle("Take a photo (iPhone)", "attach", "camera"); toggle("Choose from photos", "attach", "library"); toggle("Attach files", "attach", "files")
            }
        case "topics":
            Section {
                ForEach(family.topics, id:\.id) { topic in
                    Picker(topic.label, selection:Binding(get:{ (profile.section("topics")[topic.id] as? String) ?? "allow" }, set:{ set("topics", topic.id, $0) })) {
                        Text("Allow").tag("allow"); Text("Careful").tag("careful"); Text("Block").tag("block")
                    }
                }
                Button("Reset to the age \(profile.age) defaults") { profile.raw["topics"] = family.preset(profile.age) }
            } footer: { Text("Careful answers gently and suggests talking to you. Sexual content is always blocked, homework always gets an offer to explain instead, and self-harm always gets a caring reply pointing to a trusted adult and 988.") }
        case "ask":
            Section("How Ask answers") {
                Picker("Style", selection:Binding(get:{ profile.value("style", "wonder") }, set:{ profile.raw["style"] = $0 })) {
                    Text("Short and simple").tag("short"); Text("Explain and wonder").tag("wonder"); Text("Guess first").tag("guess")
                }
                Stepper("Age: \(profile.age)", value:Binding(get:{ profile.age }, set:{ profile.raw["age"] = $0 }), in:4...17)
                TextField("What \(profile.name) calls you (e.g. Dad)", text:Binding(get:{ profile.value("parentName", "") }, set:{ profile.raw["parentName"] = String($0.prefix(40)) }))
            }
            Section {
                TextField("Message for a blocked question", text:Binding(get:{ profile.value("refusal", "") }, set:{ profile.raw["refusal"] = String($0.prefix(200)) }), axis:.vertical).lineLimit(2...4)
            } header: { Text("Refusal message") } footer: { Text("\(profile.value("refusal", "").count)/200. Shown as an ordinary reply, without naming a rule or topic.") }
        case "rules":
            Section {
                let rules = profile.value("rules", [String]())
                ForEach(Array(rules.enumerated()), id:\.offset) { index, rule in
                    HStack { Text(rule); Spacer(); Button { var list = rules; list.remove(at:index); profile.raw["rules"] = list } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless) }
                }
                HStack {
                    TextField("For example: No video game cheats or hacks", text:$newRule).onSubmit(addRule)
                    Button("Add", action:addRule).disabled(newRule.trimmingCharacters(in:.whitespaces).isEmpty || rules.count >= 20)
                }
            } header: { Text("Your own rules") } footer: { Text("Up to 20 rules of 160 characters. Each is checked on every question and answer. Rules about style, like \"Answer in Tamil when asked\", shape answers instead of blocking.") }
        case "connection":
            Section {
                Picker("Provider", selection:Binding(get:{ (profile.section("connection")["provider"] as? String) ?? "anthropic" }, set:{ set("connection", "provider", $0) })) {
                    Text("Anthropic").tag("anthropic"); Text("OpenAI").tag("openai"); Text("OpenAI-compatible server").tag("compatible")
                }
                TextField("Model ID", text:Binding(get:{ (profile.section("connection")["model"] as? String) ?? "" }, set:{ set("connection", "model", $0) }))
                if profile.section("connection")["provider"] as? String == "compatible" {
                    TextField("API base URL", text:Binding(get:{ (profile.section("connection")["baseURL"] as? String) ?? "" }, set:{ set("connection", "baseURL", $0) }))
                }
                SecureField("API key", text:Binding(get:{ (profile.section("connection")["apiKey"] as? String) ?? "" }, set:{ set("connection", "apiKey", $0) }))
            } header: { Text("AI connection") } footer: { Text("Use a separate key for each child, with a monthly spending cap set at the provider. The model must accept images, because attached photos are checked too. \(profile.name) never sees the provider, model or key.") }
        default:
            Section("Tools") {
                toggle("Browse the web", "tools", "web"); toggle("Save notes and journal entries when asked", "tools", "editNotes")
            }
            Section("Time") {
                Stepper("Questions per day: \(profile.section("limits")["messagesPerDay"] as? Int ?? 40)", value:Binding(get:{ profile.section("limits")["messagesPerDay"] as? Int ?? 40 }, set:{ set("limits", "messagesPerDay", $0) }), in:5...200, step:5)
                Toggle("Quiet hours", isOn:Binding(get:{ profile.section("limits")["quietHours"] is [String] }, set:{ set("limits", "quietHours", $0 ? ["21:00","07:00"] : NSNull()) }))
                if let quiet = profile.section("limits")["quietHours"] as? [String], quiet.count == 2 {
                    HStack {
                        Text("From")
                        TextField("21:00", text:Binding(get:{ quiet[0] }, set:{ set("limits", "quietHours", [$0, quiet[1]]) })).frame(width:70)
                        Text("to")
                        TextField("07:00", text:Binding(get:{ quiet[1] }, set:{ set("limits", "quietHours", [quiet[0], $0]) })).frame(width:70)
                        Spacer()
                        Text("24-hour").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func set(_ section: String, _ key: String, _ value: Any) { var values = profile.section(section); values[key] = value; profile.raw[section] = values }
    private func toggle(_ title: String, _ section: String, _ key: String) -> some View {
        Toggle(title, isOn:Binding(get:{ profile.section(section)[key] as? Bool ?? false }, set:{ set(section, key, $0) }))
    }
    private func appValue(_ app: String, _ key: String) -> Any? { (profile.section("apps")[app] as? [String:Any])?[key] }
    private func appOn(_ app: String) -> Bool { appValue(app, "on") as? Bool ?? false }
    private func setApp(_ app: String, _ key: String, _ value: Any) { var apps = profile.section("apps"); var entry = apps[app] as? [String:Any] ?? [:]; entry[key] = value; apps[app] = entry; profile.raw["apps"] = apps }
    private var allowance: Double { (appValue("money", "allowance") as? NSNumber)?.doubleValue ?? 0 }
    private func appToggle(_ title: String, _ app: String) -> some View {
        Toggle(title, isOn:Binding(get:{ (profile.section("apps")[app] as? [String:Any])?["on"] as? Bool ?? false }, set:{ var apps = profile.section("apps"); var entry = apps[app] as? [String:Any] ?? [:]; entry["on"] = $0; apps[app] = entry; profile.raw["apps"] = apps }))
    }
    private func sharing(_ key: String) -> Any? { profile.section("sharing")[key] }
    private func setSharing(_ key: String, _ value: Any) { set("sharing", key, value) }
    private func addEmail() {
        let email = newEmail.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count <= 200 else { return }
        var emails = sharing("family") as? [String] ?? []
        if !emails.contains(email), emails.count < 20 { emails.append(email); setSharing("family", emails) }
        newEmail = ""
    }
    private func addRule() {
        let rule = String(newRule.trimmingCharacters(in:.whitespacesAndNewlines).prefix(160))
        guard !rule.isEmpty else { return }
        var rules = profile.value("rules", [String]()); guard rules.count < 20 else { return }
        rules.append(rule); profile.raw["rules"] = rules; newRule = ""
    }
    private func publish() {
        family.save(profile)
        do {
            let data = try family.publish(profile)
            refresh()
            exportName = "\(profile.name) rules v\(profile.version).json"
            exportFile = RulesFile(data:data)
        } catch { family.error = error.localizedDescription }
    }
    private func refresh() { if let updated = family.children.first(where: { $0.id == profile.id }) { profile = updated } }
}

/// The code a child's device joins with: a QR code to scan on iPhone, or text
/// to paste on a Mac. It holds the child's family key, so it's shown only here
/// and expires in 10 minutes.
struct EnrollmentSheet: View {
    let name: String, code: String, confirmation: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(spacing:16) {
            Text("Add one of \(name)'s devices").font(.title2.weight(.semibold))
            Text("On \(name)'s device, open Settings → Family, then scan this code or paste it under \"Is this your child's device?\"").multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let image = QRCode.image(code) { image.interpolation(.none).resizable().frame(width:220, height:220) }
            Button(copied ? "Copied" : "Copy Code") { copyCode(); copied = true }
            VStack(spacing:4) {
                Text(confirmation).font(.system(size:30, weight:.medium, design:.monospaced)).tracking(4)
                Text("Their screen shows this number after joining. The code expires in 10 minutes.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("Then publish. With iCloud on, their device picks up the rules within a minute; otherwise install the rules file there.").font(.caption).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        #if os(macOS)
        .frame(width:440)
        #endif
    }
    private func copyCode() {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType:.string)
        #else
        UIPasteboard.general.string = code
        #endif
    }
}

enum QRCode {
    static func image(_ text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8, y:8)),
              let cgImage = CIContext().createCGImage(output, from:output.extent) else { return nil }
        return Image(decorative:cgImage, scale:1)
    }
}
