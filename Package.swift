// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ShizukuCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ShizukuCore",
            targets: ["ShizukuCore"]
        ),
    ],
    dependencies: [
        // 刻意保持零外部依赖:系统 SQLite3 + Foundation 已覆盖全部需求。
        // 避免 GitHub 网络不可达导致构建失败(用户网络环境实测 github.com 超时)。
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ShizukuCore",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "ShizukuCoreTests",
            dependencies: ["ShizukuCore"],
            exclude: [
                "Fixtures",  // 假 MCP 服务器脚本,通过 #filePath 运行时定位,不入包
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
