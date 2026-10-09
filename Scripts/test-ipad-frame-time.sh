#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: test-ipad-frame-time.sh <device-udid> <development-team>" >&2
    exit 2
fi
for tool in python3 xcodegen xcodebuild; do
    command -v "$tool" >/dev/null || { echo "required tool: $tool" >&2; exit 1; }
done

repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
review_workspace=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-ipad.XXXXXX")
echo "Benchmark workspace (including results): $review_workspace"

# SwiftPM's tool-hosted tests cannot run on a physical iPad. Generate an
# application host outside the repository and link the existing renderer tests.
python3 - "$review_workspace" "$repository_root" "$2" <<'PY'
from pathlib import Path
import json
import sys

workspace, repository, team = sys.argv[1:]
root = Path(workspace)
(root / 'App.swift').write_text('''import SwiftUI
@main struct FrameReviewApp: App {
    var body: some Scene {
        WindowGroup { Text("Swiftty renderer benchmark") }
    }
}
''')
project = {
    'name': 'SwifttyFrameReview',
    'options': {'deploymentTarget': {'iOS': '27.0'}},
    'settings': {'base': {
        'DEVELOPMENT_TEAM': team, 'CODE_SIGN_STYLE': 'Automatic',
        'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES',
    }},
    'packages': {'Swiftty': {'path': repository}},
    'targets': {
        'SwifttyFrameReview': {
            'type': 'application', 'platform': 'iOS', 'sources': ['App.swift'],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.chr33s.swiftty.review.renderer',
                'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
            }},
        },
        'FrameTests': {
            'type': 'bundle.unit-test', 'platform': 'iOS',
            'sources': [str(Path(repository) / 'Tests/SwifttyMobileTests/FrameTimeTests.swift')],
            'dependencies': [
                {'target': 'SwifttyFrameReview'},
                {'package': 'Swiftty', 'product': 'SwifttyCore'},
            ],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.chr33s.swiftty.review.renderer.tests',
                'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/SwifttyFrameReview.app/SwifttyFrameReview',
                'BUNDLE_LOADER': '$(TEST_HOST)',
            }},
        },
    },
    'schemes': {'SwifttyFrameReview': {
        'build': {'targets': {'SwifttyFrameReview': 'all', 'FrameTests': ['test']}},
        'test': {'targets': ['FrameTests']},
    }},
}
(root / 'project.json').write_text(json.dumps(project, indent=2) + '\n')
PY

cd "$review_workspace"
xcodegen generate --spec project.json
xcodebuild -scheme SwifttyFrameReview -configuration Release \
    -destination "platform=iOS,id=$1" -derivedDataPath "$review_workspace/build" \
    -collect-test-diagnostics never test
