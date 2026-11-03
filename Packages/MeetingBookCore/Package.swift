// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MeetingBookCore", platforms: [.iOS(.v26), .macOS(.v15)], products: [.library(name: "MeetingBookCore", targets: ["MeetingBookCore"])], targets: [.target(name: "MeetingBookCore", resources: [.process("Templates/Resources")]), .testTarget(name: "MeetingBookCoreTests", dependencies: ["MeetingBookCore"], resources: [.process("Fixtures")])])
