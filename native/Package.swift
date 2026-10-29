// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NotebookNative", platforms: [.macOS(.v14), .iOS(.v17)], products: [
    .library(name: "NotebookCore", targets: ["NotebookCore"])
], targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "NotebookCore", dependencies: ["CSQLite"]),
    .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"])
])
