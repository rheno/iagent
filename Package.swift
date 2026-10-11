// swift-tools-version:5.9
import Foundation
import PackageDescription

// The Info.plist is embedded into the binary so macOS can show proper privacy prompts
// (Reminders, Calendars, Contacts) for this command-line tool.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path
// The app icon is embedded the same way, for the REPL banner in terminals that draw images.
let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("assets/icons/icon-128.png").path

let package = Package(
    name: "iAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iagent", targets: ["iAgent"]),
    ],
    targets: [
        .executableTarget(
            name: "iAgent",
            path: "Sources/iAgent",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__iagent_icon", "-Xlinker", icon]),
            ]
        ),
        .testTarget(
            name: "iAgentTests",
            dependencies: ["iAgent"],
            path: "Tests/iAgentTests"
        ),
    ]
)
