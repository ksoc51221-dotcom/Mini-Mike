// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Merlin",
    platforms: [.macOS("26.0")], // on-device transcription uses macOS 26's SpeechAnalyzer
    targets: [
        // Vendored MIT typesetter for LaTeX maths (see Sources/SwiftMath/README-VENDORED.md).
        .target(name: "SwiftMath", path: "Sources/SwiftMath", exclude: ["LICENSE", "README-VENDORED.md"]),
        .executableTarget(
            name: "Merlin",
            dependencies: ["SwiftMath"],
            path: "Sources/Merlin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Speech"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("EventKit"),
            ]
        )
    ]
)
