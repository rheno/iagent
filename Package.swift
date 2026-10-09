// swift-tools-version:5.9
import Foundation
import PackageDescription

// The Info.plist is embedded into the binary so macOS can show proper privacy prompts
// (Reminders, Calendars, Contacts) for this command-line tool.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

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
            ]
        ),
        .testTarget(
            name: "iAgentTests",
            dependencies: ["iAgent"],
            path: "Tests/iAgentTests"
        ),
    ]
)
