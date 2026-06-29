#!/bin/bash
# volta 빌드 스크립트
# - 빌드 결과를 프로젝트 폴더 안 ./build 로 보낸다(기본 DerivedData 대신).
# - error: 줄만 추려서 보여준다.
# 사용법:  ./build.sh          (앱 빌드)
#          ./build.sh run      (빌드 후 실행)
#          ./build.sh test     (VoltaCore 로직 테스트)

set -o pipefail
cd "$(dirname "$0")"

DERIVED="./build"
APP="$DERIVED/Build/Products/Debug/volta.app"

case "$1" in
  test)
    echo "▶︎ VoltaCore 로직 테스트…"
    cd Packages/VoltaCore && swift test
    ;;
  *)
    echo "▶︎ 빌드 중… (결과: $DERIVED)"
    xcodebuild \
      -project volta.xcodeproj \
      -scheme volta \
      -configuration Debug \
      -derivedDataPath "$DERIVED" \
      build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
    rc=$?
    echo ""
    if [ -d "$APP" ]; then
      echo "✅ 앱 위치: $APP"
      if [ "$1" = "run" ]; then
        echo "▶︎ 실행…"
        open "$APP"
      fi
    fi
    exit $rc
    ;;
esac
