// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Search",
            // Fork (voice): Fermion Research's greedy-TDT decoder in C, under
            // the speech runner vendored in Fork/Voice/Phonon (Apache-2.0).
            dependencies: ["PhononTDT"],
            path: "Sources/Search",
            // The runner's LICENSE and NOTICE travel with its sources; they
            // are kept beside them, not built or bundled.
            exclude: ["Fork/Voice/Phonon/LICENSE", "Fork/Voice/Phonon/NOTICE"],
            // The animated space backdrop's page and its three.js, copied as a
            // folder into Search_Search.bundle beside the binary (build.sh
            // carries that bundle into the app; Fork/AnimatedBackdrop.swift
            // looks in both places). The canvas page rides the same way
            // (Fork/Canvas/CanvasHost.swift, CanvasPage).
            resources: [.copy("Fork/Backdrop"), .copy("Fork/Canvas/Resources"), .copy("Fork/Addons/Resources/bridge.js")], // Fork (addons): the bridge shim, verbatim (Fork/Addons/AddonHost.swift)
            // The runner's log-mel front end multiplies with cblas_sgemm;
            // Accelerate's current BLAS headers (macOS 13.3+) are the ones
            // that don't mark it deprecated. Nothing else here uses BLAS.
            cSettings: [.define("ACCELERATE_NEW_LAPACK")],
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Fork (voice): vendored C, plain (no settings), as upstream builds it.
        .target(name: "PhononTDT", path: "Sources/PhononTDT"),
        // `swift test`: the pure parts that need no window — so far the
        // crash-report reader and the breadcrumb trail (Fork/Crashes.swift).
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            path: "Tests/SearchTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
