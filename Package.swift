// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SipAwake",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "sipawake", targets: ["SipAwake"])],
    targets: [
        .executableTarget(name: "SipAwake"),
        .testTarget(name: "SipAwakeTests", dependencies: ["SipAwake"])
    ]
)
