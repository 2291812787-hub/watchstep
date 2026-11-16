// swift-tools-version:5.9
import PackageDescription

// 只打包"纯逻辑"那三个文件（Config / AnchorStore / RuleEngine）。
// 它们不 import WatchKit / CoreMotion，所以能在 Linux 上跑 —— 
// 于是状态机和验收标准可以真执行测试，而不是靠我肉眼读。
// 手表 App 本身由 Xcode 工程编译（GitHub Actions 的 macOS runner）。
let package = Package(
    name: "WatchStepCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "WatchStepCore", targets: ["WatchStepCore"])
    ],
    targets: [
        .target(
            name: "WatchStepCore",
            path: "Sources/WatchStepCore"
        ),
        .testTarget(
            name: "WatchStepCoreTests",
            dependencies: ["WatchStepCore"],
            path: "Tests/WatchStepCoreTests"
        )
    ]
)
