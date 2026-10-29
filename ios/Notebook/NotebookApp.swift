import SwiftUI
import UIKit
import NotebookCore
import CloudKit

/// Receives invitations the person taps (a shared note's link, say), at launch
/// or while running. They wait until Notebook is unlocked, then are accepted.
final class NotebookSceneDelegate: NSObject, UIWindowSceneDelegate {
    @MainActor private static var pending: [CKShare.Metadata] = []
    @MainActor private static weak var model: NotebookModel?
    @MainActor static func attach(_ model: NotebookModel) { self.model = model; flush() }
    @MainActor private static func flush() {
        guard let model, model.unlocked else { return }
        let waiting = pending; pending = []
        for metadata in waiting { Task { await model.sharing.accept(metadata) } }
    }
    @MainActor static func received(_ metadata: CKShare.Metadata) { pending.append(metadata); flush() }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { MainActor.assumeIsolated { Self.received(metadata) } }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        MainActor.assumeIsolated { Self.received(metadata) }
    }
}

final class NotebookAppDelegate: NSObject, UIApplicationDelegate {
    static var sync: (() async -> Void)?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        if CloudSync.provisioned(container:Bundle.main.object(forInfoDictionaryKey:"NotebookCloudContainer") as? String ?? CloudSync.defaultContainer) { application.registerForRemoteNotifications() }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name:nil, sessionRole:session.role)
        configuration.delegateClass = NotebookSceneDelegate.self
        return configuration
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable:Any], fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { await Self.sync?(); completion(.newData) }
    }
}
@main struct NotebookApp: App {
    @UIApplicationDelegateAdaptor(NotebookAppDelegate.self) var delegate
    private let model: NotebookModel?
    private let startupError: String?
    init() {
        do {
            var directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Notebook")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                directory = directory.deletingLastPathComponent().appendingPathComponent("NotebookUITests")
                if ProcessInfo.processInfo.arguments.contains("--reset-ui-test-data") { try? FileManager.default.removeItem(at:directory) }
                UserDefaults.standard.set(false,forKey:"notebook-lock")
            }
            #endif
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:directory.path)
            let store = try RecordStore(url:directory.appendingPathComponent("notebook.sqlite"))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-test-data"), ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               let value=ProcessInfo.processInfo.environment["NOTEBOOK_TEST_LIBRARY_SIZE"], let count=Int(value) {
                for index in 0..<min(max(count,0),3000) {
                    _ = try store.save(kind:"notes",record:["id":"seed-\(index)","title":"Library note \(index)","content":String(repeating:"Existing text. ",count:100),"modifiedAt":"2026-01-01T00:00:00Z"])
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let fixture = ProcessInfo.processInfo.environment["NOTEBOOK_FINANCE_TEST_EXPORT"] {
                let finance = FinanceModel(store:store,authorized:{true})
                finance.applyImport(try finance.parseImport(Data(fixture.utf8)))
                if let error = finance.error { throw NotebookError.message(error) }
            }
            #endif
            model = NotebookModel(store:store); startupError = nil
        } catch { model = nil; startupError = error.localizedDescription }
    }
    var body: some Scene {
        WindowGroup {
            if let model { NotebookRoot(model:model).onAppear { NotebookAppDelegate.sync = { [weak model] in await model?.sync() } } }
            else { ContentUnavailableView("Notebook could not open",systemImage:"externaldrive.badge.exclamationmark",description:Text(startupError ?? "Your data has not been changed.")) }
        }
    }
}
