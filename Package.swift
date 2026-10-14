// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Folio", targets: ["Folio"]),
               .executable(name: "shelf-bench", targets: ["ShelfBench"]),
               .executable(name: "folio-tool", targets: ["FolioTool"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ShelfCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Folio", dependencies: ["ShelfCore"]),
        .executableTarget(name: "ShelfBench", dependencies: ["ShelfCore"]),
        .executableTarget(name: "FolioTool", dependencies: ["ShelfCore"]),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"])
    ],
    swiftLanguageVersions: [.v5]
)
