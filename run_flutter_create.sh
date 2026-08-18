#!/bin/bash
export PATH="/c/Program Files/Git/bin:$PATH"

cd /d/workspace/venera

echo "=== Flutter Doctor Check ==="
"/c/Users/30923/.workbuddy/binaries/flutter/sdk/flutter/bin/flutter.bat" doctor --verbose 2>&1

echo "=== Creating OHOS Platform ==="
"/c/Users/30923/.workbuddy/binaries/flutter/sdk/flutter/bin/flutter.bat" create --platforms=ohos . 2>&1

echo "=== Done ==="
