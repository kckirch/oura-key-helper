// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OuraKeyHelper", platforms: [.macOS(.v13)], products: [.executable(name: "OuraKeyHelper", targets: ["OuraKeyHelper"])], targets: [.target(name: "KeyReader", linkerSettings: [.linkedLibrary("sqlite3")]), .executableTarget(name: "OuraKeyHelper", dependencies: ["KeyReader"]), .testTarget(name: "KeyReaderTests", dependencies: ["KeyReader"])])
