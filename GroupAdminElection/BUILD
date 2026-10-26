load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "GroupAdminElectionCore",
    module_name = "GroupAdminElectionCore",
    srcs = glob([
        "Core/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_test(
    name = "GroupAdminElectionCoreTests",
    srcs = [
        "Tests/GroupAdminElectionCoreTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":GroupAdminElectionCore",
    ],
)

swift_library(
    name = "GroupAdminElection",
    module_name = "GroupAdminElection",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":GroupAdminElectionCore",
        "//submodules/AccountContext",
        "//submodules/ComponentFlow",
        "//submodules/ConfettiEffect",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/Components/SheetComponent",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Display",
        "//submodules/PresentationDataUtils",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramUI/Components/AvatarComponent",
        "//submodules/TelegramUI/Components/ButtonComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)
