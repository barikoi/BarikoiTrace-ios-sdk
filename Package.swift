// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BarikoiTrace",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "BarikoiTrace", targets: ["BarikoiTrace"])
    ],
    dependencies: [
        // MQTT 3.1.1 client. Pin/verify the exact tag against what's current
        // when you first resolve this package — check
        // https://github.com/emqx/CocoaMQTT for the latest release before building.
        .package(url: "https://github.com/emqx/CocoaMQTT.git", from: "2.1.6")
    ],
    targets: [
        .target(
            name: "BarikoiTrace",
            dependencies: [
                .product(name: "CocoaMQTT", package: "CocoaMQTT")
            ],
            path: "Sources/BarikoiTrace",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "BarikoiTraceTests",
            dependencies: ["BarikoiTrace"],
            path: "Tests/BarikoiTraceTests"
        )
    ]
)
