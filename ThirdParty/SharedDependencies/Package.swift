// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let localBuildHeaders = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build-headers/boost").path

let package = Package(
    name: "SharedDependencies",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "SharedDependencies", targets: [
            "SharedDependencies"
        ])
    ],
    dependencies: [
        .package(url: "https://github.com/jarrodnorwell/PLzmaSDK", revision: "c69ff6acb4df788885cc4865d46e1a442e6f50a5"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", revision: "4b1188ba947ddc23d03b13096b9e44b804e146c9")
    ],
    targets: [
        .target(name: "SharedDependencies", dependencies: [
            "lib_enet",
            "lib_faad2",
            "lib_fmt",
            "lib_glslang",
            "lib_machineindependent",
            "lib_sirit",
            "lib_spirv",
            "lib_teakra",

            "cereal",
            "cryptopp",
            "dds_ktx",
            "eventbus",
            "glib",
            "httplib",
            "inih",
            "libchdr",
            "libslirp",
            "lodepng",
            "magic_enum",
            "metal_cpp",
            "microprofile",
            "miniz",
            "nihstro",
            "nlohmann",
            "osa",
            "stb",
            "tsl",
            "xxhash"
        ]),
        .target(name: "cereal", publicHeadersPath: "include"),
        .target(name: "cryptopp", publicHeadersPath: "include", cxxSettings: [
            .define("CRYPTOPP_DISABLE_ARM_CRC32"),
            .headerSearchPath("include/cryptopp"),
            .unsafeFlags([
                "-Wno-implicit-int-conversion",
                "-Wno-shorten-64-to-32"
            ])
        ]),
        .target(name: "dds_ktx", publicHeadersPath: "include"),
        .target(name: "eventbus", publicHeadersPath: "include"),
        .target(name: "glib",
                publicHeadersPath: "include",
                cSettings: [
                    .unsafeFlags([
                        "-Wno-implicit-int-conversion",
                        "-Wno-shorten-64-to-32"
                    ])
                ]),
        .target(name: "httplib",
                dependencies: ["OpenSSL"],
                publicHeadersPath: "include",
                cxxSettings: [
                    .define("CPPHTTPLIB_OPENSSL_SUPPORT")
                ]),
        .target(name: "inih", publicHeadersPath: "include"),
        .target(name: "libchdr",
                dependencies: [
                    "FLAC",
                    "ogg",
                    .product(name: "PLzmaSDK-Static", package: "PLzmaSDK")
                ], publicHeadersPath: "include",
                cSettings: [
                    .unsafeFlags([
                        "-Wno-shorten-64-to-32"
                    ])
                ]),
        .target(name: "libslirp", dependencies: [
            "glib"
        ], publicHeadersPath: "include", cSettings: [
            .unsafeFlags([
                "-D_NETINET_TCP_VAR_H_",
                "-ffast-math",
                "-Wno-implicit-int-conversion",
                "-Wno-shorten-64-to-32"
            ])
        ]),
        .target(name: "lodepng", publicHeadersPath: "include"),
        .target(name: "magic_enum", publicHeadersPath: "include"),
        .target(name: "metal_cpp", publicHeadersPath: "include"),
        .target(name: "microprofile",
                publicHeadersPath: "include",
                cxxSettings: [
                    // Match the disabled profiling policy in common/microprofile.h.
                    .define("MICROPROFILE_ENABLED", to: "0"),
                    .define("MICROPROFILE_WEBSERVER", to: "0"),
                    .define("MICROPROFILE_GPU_TIMERS", to: "0"),
                    .define("MICROPROFILE_CONTEXT_SWITCH_TRACE", to: "0"),
                    .unsafeFlags([
                        "-Wno-implicit-int-conversion",
                        "-Wno-shorten-64-to-32"
                    ])
                ]),
        .target(name: "miniz", publicHeadersPath: "include"),
        .target(name: "nihstro",
                // The iPhone renderer consumes binary shaders, not desktop shader assembly.
                exclude: [
                    "assembler.cpp", "disassembler.cpp", "preprocessor.cpp",
                    "parser_assembly.cpp", "parser_assembly"
                ],
                publicHeadersPath: "include",
                cxxSettings: [
                    .unsafeFlags([
                        "-I\(localBuildHeaders)",
                        "-I/opt/homebrew/include",
                        "-I/opt/homebrew/include/boost",
                        "-I/usr/local/include"
                    ])
                ]),
        .target(name: "nlohmann", publicHeadersPath: "include"),
        .target(name: "osa", publicHeadersPath: "include"),
        .target(name: "stb", publicHeadersPath: "include"),
        .target(name: "tsl", publicHeadersPath: "include"),
        .target(name: "xxhash", publicHeadersPath: "include"),

        .binaryTarget(name: "lib_enet", path: "Artifacts/lib_enet.xcframework"),

        .binaryTarget(name: "lib_faad2", path: "Artifacts/lib_faad2.xcframework"),

        .binaryTarget(name: "lib_fmt", path: "Artifacts/lib_fmt.xcframework"),

        .binaryTarget(name: "lib_glslang", path: "Artifacts/lib_glslang.xcframework"),
        .binaryTarget(name: "lib_machineindependent", path: "Artifacts/lib_machineindependent.xcframework"),

        .binaryTarget(name: "lib_sirit", path: "Artifacts/lib_sirit.xcframework"),

        .binaryTarget(name: "lib_spirv", path: "Artifacts/lib_spirv.xcframework"),

        .binaryTarget(name: "lib_teakra", path: "Artifacts/lib_teakra.xcframework"),

        .binaryTarget(name: "FLAC",
                      url: "https://github.com/sbooth/flac-binary-xcframework/releases/download/0.2.0/FLAC.xcframework.zip",
                      checksum: "87f1b13fb490867790b96d52fcbeb1a23847b8f45f50cece530d533266c2001e"),
        .binaryTarget(name: "ogg",
                      url: "https://github.com/sbooth/ogg-binary-xcframework/releases/download/0.1.3/ogg.xcframework.zip",
                      checksum: "0c06ea645c6ca187e66442717eb856c09e2b969545e880300639b41f7b83ae98")
    ],
    cLanguageStandard: .gnu2x,
    cxxLanguageStandard: .gnucxx2b
)

// Xcode project settings do not propagate into separately generated package targets.
let mobileDefinitions: [(String, String)] = [
    ("ENABLE_WEB_SERVICE", "0"),
    ("CITRA_USE_DISCORD_PRESENCE", "0"),
    ("ENABLE_QT", "0"),
    ("DISABLE_JIT", "1"),
    ("STRICT_INTERPRETER", "1"),
    ("ENABLE_REMOTE_INPUT", "0")
]
for target in package.targets where target.type == .regular && target.name != "SharedDependencies" {
    target.cSettings = (target.cSettings ?? []) + mobileDefinitions.map {
        CSetting.define($0.0, to: $0.1, .when(platforms: [.iOS]))
    }
    target.cxxSettings = (target.cxxSettings ?? []) + mobileDefinitions.map {
        CXXSetting.define($0.0, to: $0.1, .when(platforms: [.iOS]))
    }
}
