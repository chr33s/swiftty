#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: test-ios-simulator.sh <simulator-udid>" >&2
    exit 2
fi
for tool in python3 xcodegen xcodebuild; do
    command -v "$tool" >/dev/null || { echo "required tool: $tool" >&2; exit 1; }
done

repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
review_workspace=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-simulator.XXXXXX")
echo "Simulator test workspace (including results): $review_workspace"

# A running application is needed to test UIKit control dispatch and its
# accessibility defaults. The wrapper also exposes the shared test support
# target without changing the repository's public package products.
python3 - "$review_workspace" "$repository_root" <<'PY'
from pathlib import Path
import json
import sys

workspace, repository = map(Path, sys.argv[1:])
package = workspace / 'Package'
package.mkdir()
for name in ('Sources', 'Tests'):
    (package / name).symlink_to(repository / name, target_is_directory=True)
(package / 'Package.swift').write_text('''// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "SimulatorReviewPackage",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "SwifttyCore", targets: ["SwifttyCore"]),
        .library(name: "SwifttyMobile", targets: ["SwifttyMobile"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        .target(name: "SwifttyCore", resources: [.copy("Renderer/Shaders.metal")],
                swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
        .target(name: "SwifttyMobile", dependencies: ["SwifttyCore"]),
        .target(name: "TestSupport", path: "Tests/Support"),
    ]
)
''')
(workspace / 'App.swift').write_text('''import SwiftUI
@main struct SimulatorReviewApp: App {
    var body: some Scene {
        WindowGroup { Text("Swiftty simulator tests") }
    }
}
''')
# ReplayTests normally gets this accessor from SwiftPM. Here the fixtures are
# copied into the hosted test bundle by Xcode instead.
(workspace / 'TestResources.swift').write_text('''import Foundation
private final class TestResources: NSObject {}
extension Bundle {
    static var module: Bundle { Bundle(for: TestResources.self) }
}
''')
sources = [{'path': str(path)} for directory in (
    repository / 'Tests/SwifttyMobileTests',
    repository / 'Tests/SwifttyMobileHostedTests',
) for path in sorted(directory.glob('*.swift'))]
sources += [
    {'path': 'TestResources.swift'},
    {'path': str(repository / 'Tests/SwifttyMobileTests/Fixtures'),
     'type': 'folder', 'buildPhase': 'resources'},
]
project = {
    'name': 'SwifttySimulatorReview',
    'options': {'deploymentTarget': {'iOS': '27.0'}},
    'settings': {'base': {
        'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES',
        'ENABLE_TESTABILITY': 'YES', 'CODE_SIGNING_ALLOWED': 'NO',
    }},
    'packages': {'SwifttyReview': {'path': str(package)}},
    'targets': {
        'SimulatorReview': {
            'type': 'application', 'platform': 'iOS', 'sources': ['App.swift'],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.chr33s.swiftty.review.simulator',
                'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
                'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES',
            }},
        },
        'MobileTests': {
            'type': 'bundle.unit-test', 'platform': 'iOS', 'sources': sources,
            'dependencies': [
                {'target': 'SimulatorReview'},
                *({'package': 'SwifttyReview', 'product': product}
                  for product in ('SwifttyCore', 'SwifttyMobile', 'TestSupport')),
            ],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.chr33s.swiftty.review.simulator.tests',
                'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/SimulatorReview.app/SimulatorReview',
                'BUNDLE_LOADER': '$(TEST_HOST)',
            }},
        },
    },
    'schemes': {'SwifttySimulatorReview': {
        'build': {'targets': {'SimulatorReview': 'all', 'MobileTests': ['test']}},
        'test': {'targets': ['MobileTests']},
    }},
}
(workspace / 'project.json').write_text(json.dumps(project, indent=2) + '\n')
PY

cd "$review_workspace"
xcodegen generate --spec project.json
xcodebuild -scheme SwifttySimulatorReview -configuration Release \
    -destination "platform=iOS Simulator,id=$1" -derivedDataPath "$review_workspace/build" \
    -collect-test-diagnostics never ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES test
