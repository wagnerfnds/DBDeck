// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DBDeck",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DBDeckCore", targets: ["DBDeckCore"]),
        .executable(name: "DBDeck", targets: ["DBDeckApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
        .package(path: "ThirdParty/mysql-nio"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    ],
    targets: [
        .target(
            name: "DBDeckCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .executableTarget(
            name: "DBDeckApp",
            dependencies: ["DBDeckCore"]
        ),
        .testTarget(
            name: "DBDeckCoreTests",
            dependencies: ["DBDeckCore"]
        ),
    ]
)
