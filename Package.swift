// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BookSourceFetcher",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "BookSourceFetcher", targets: ["BookSourceFetcher"]),
        .executable(name: "fetcher-cli", targets: ["fetcher-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "BookSourceFetcher",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            resources: [
                .copy("Resources/usable_sources.json")
            ]
        ),
        .executableTarget(
            name: "fetcher-cli",
            dependencies: ["BookSourceFetcher"]
        ),
        .testTarget(
            name: "BookSourceFetcherTests",
            dependencies: ["BookSourceFetcher"]
        )
    ]
)
