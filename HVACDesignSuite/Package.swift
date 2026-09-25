// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HVACDesignSuite",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HVACCore", targets: ["HVACCore"]),
        .library(name: "HVACUI", targets: ["HVACUI"]),
        .executable(name: "HVACDesignSuite", targets: ["HVACDesignSuiteApp"])
    ],
    targets: [
        .target(name: "HVACCore"),
        .target(name: "HVACUI", dependencies: ["HVACCore"]),
        .executableTarget(name: "HVACDesignSuiteApp", dependencies: ["HVACUI"]),
        .testTarget(name: "HVACCoreTests", dependencies: ["HVACCore", "HVACUI"])
    ]
)
