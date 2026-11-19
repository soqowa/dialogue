// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dialog",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Dialog", targets: ["Dialog"]), .executable(name: "DialogSpeech", targets: ["DialogSpeech"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "313feb4bd692780a9a5b5fa9048fdb119486dde8")
    ],
    targets: [.executableTarget(name: "Dialog", dependencies: [
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark")
    ], linkerSettings: [
        .linkedFramework("SwiftUI"), .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("AVFoundation"), .linkedFramework("CoreMedia"), .linkedFramework("Carbon")
    ]), .executableTarget(name: "DialogSpeech", dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio")
    ]), .testTarget(name: "DialogTests", dependencies: ["Dialog"])],
    swiftLanguageModes: [.v5]
)
