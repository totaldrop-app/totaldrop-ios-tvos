// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "TotalDropTV",
    defaultLocalization: "en",
    platforms: [
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "TotalDropTV",
            targets: ["TotalDropTV"]
        ),
    ],
    targets: [
        .target(
            name: "CTotalDropAppleMobileFFI",
            path: "Sources/CTotalDropAppleMobileFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "TotalDropTV",
            dependencies: ["CTotalDropAppleMobileFFI"],
            path: "Sources/TotalDropTV",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("UIKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
