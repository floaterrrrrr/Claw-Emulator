// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "zstd",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "libzstd",
            targets: [ "libzstd" ]),
        .library(
            name: "libzstdwrapper",
            targets: [ "libzstdwrapper" ]),
        .library(
            name: "libseekable_format",
            targets: [ "libseekable_format" ])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "libseekable_format",
            dependencies: [ "libzstd" ],
            path: "contrib",
            exclude: [
                "seekable_format/examples", "seekable_format/tests",
                "seekable_format/README.md", "seekable_format/zstd_seekable_compression_format.md"
            ],
            sources: [ "seekable_format" ],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath(".."),
                .headerSearchPath("../lib/common"),
                .define("ZSTD_STATIC_LINKING_ONLY")
            ]),
        .target(
            name: "libzstd",
            path: "lib",
            sources: [ "common", "compress", "decompress", "dictBuilder" ],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]),
        .target(
            name: "libzstdwrapper",
            path: "zlibWrapper",
            exclude: [
                "examples"
            ],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("../lib"),
                .headerSearchPath("../lib/common"),
                .headerSearchPath("../programs"),
                .define("ZSTD_STATIC_LINKING_ONLY")
            ])
    ],
    swiftLanguageModes: [
        .v6
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)

let mobileDefinitions: [(String, String)] = [
    ("ENABLE_WEB_SERVICE", "0"),
    ("CITRA_USE_DISCORD_PRESENCE", "0"),
    ("ENABLE_QT", "0"),
    ("DISABLE_JIT", "1"),
    ("STRICT_INTERPRETER", "1"),
    ("ENABLE_REMOTE_INPUT", "0")
]
for target in package.targets where target.type == .regular {
    target.cSettings = (target.cSettings ?? []) + mobileDefinitions.map {
        CSetting.define($0.0, to: $0.1, .when(platforms: [.iOS]))
    }
    target.cxxSettings = (target.cxxSettings ?? []) + mobileDefinitions.map {
        CXXSetting.define($0.0, to: $0.1, .when(platforms: [.iOS]))
    }
}
