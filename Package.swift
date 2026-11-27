// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDPreviewCoreTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FileScannerCore", path: "MDPreview"),
        .testTarget(name: "FileScannerTests", dependencies: ["FileScannerCore"], path: "Tests/FileScannerTests")
    ]
)
