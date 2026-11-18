// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SipAwake",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sipawake", targets: ["SipAwake"]),
        .executable(name: "SipAwakeMenu", targets: ["SipAwakeMenu"])
    ],
    targets: [
        .executableTarget(name: "SipAwake"),
        .executableTarget(name: "SipAwakeMenu"),
        .testTarget(name: "SipAwakeTests", dependencies: ["SipAwake"])
    ]
)
