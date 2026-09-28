// swift-tools-version:5.10
import PackageDescription

// Info.plist is embedded into the binary so TCC shows a proper
// "System Audio Recording" prompt for the command-line tools.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"
let embedInfoPlist: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                  "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
]

let package = Package(
    name: "engine",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "CAtomics"),
        .target(name: "MixerCore", dependencies: ["CAtomics"]),
        .executableTarget(
            name: "tapspike",
            dependencies: ["MixerCore"],
            linkerSettings: embedInfoPlist
        ),
        .executableTarget(
            name: "mixerd",
            dependencies: ["MixerCore"],
            linkerSettings: embedInfoPlist
        ),
    ]
)
