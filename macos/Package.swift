// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlueAudioSwitchMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "blueaudioswitch-mac", targets: ["BlueAudioSwitchMac"])
    ],
    targets: [
        .executableTarget(
            name: "BlueAudioSwitchMac",
            path: "Sources/BlueAudioSwitchMac",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
