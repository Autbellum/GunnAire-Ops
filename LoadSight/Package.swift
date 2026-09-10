// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoadSightKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LoadSightKit", targets: ["LoadSightKit"]),
               .library(name: "LoadSightUI", targets: ["LoadSightUI"]),
               .executable(name: "loadsight", targets: ["LoadSightCLI"]),
               .executable(name: "LoadSightDesktop", targets: ["LoadSightApp"])],
    targets: [
        .target(name: "LoadSightCore"),
        .target(name: "LoadSightCalc", dependencies: ["LoadSightCore"]),
        .target(name: "LoadSightTakeoff", dependencies: ["LoadSightCore"]),
        .target(name: "LoadSightIngest", dependencies: ["LoadSightCore"]),
        .target(name: "LoadSightKit", dependencies: ["LoadSightCore", "LoadSightCalc", "LoadSightTakeoff", "LoadSightIngest"]),
        .executableTarget(name: "LoadSightCLI", dependencies: ["LoadSightKit"]),
        .target(name: "LoadSightUI", dependencies: ["LoadSightKit"]),
        .executableTarget(name: "LoadSightApp", dependencies: ["LoadSightUI"]),
        .testTarget(name: "LoadSightKitTests", dependencies: ["LoadSightKit", "LoadSightUI"], resources: [.copy("Fixtures")])
    ]
)
