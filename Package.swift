// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS("26.0")], // on-device transcription uses macOS 26's SpeechAnalyzer
    targets: [
        .executableTarget(
            name: "Margin",
            path: "Sources/Margin",
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
