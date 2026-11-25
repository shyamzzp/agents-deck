// swift-tools-version:5.9
// deck-words: the helper agents deck's service asks what two requests mean.
// It speaks the line protocol in ../README.md on stdin and stdout.
import PackageDescription

let package = Package(
    name: "deck-words",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "deck-words", targets: ["deck-words"]),
    ],
    targets: [
        .executableTarget(
            name: "deck-words",
            linkerSettings: [.linkedFramework("NaturalLanguage")]
        ),
    ]
)
