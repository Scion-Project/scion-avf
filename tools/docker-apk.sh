#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the probe APK in a container, for hosts without a JDK/Android SDK:
#   tools/docker-apk.sh   ->  probe/app/app/build/outputs/apk/debug/app-debug.apk
#
# Uses eclipse-temurin:21-jdk plus Google's command-line tools to fetch platform
# 36 (the SDK licences are accepted non-interactively: by running this you accept
# them, see https://developer.android.com/studio/terms). SDK and Gradle caches
# live in ~/.cache/avf-apk-build so reruns are quick (about 1 GB).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cache="${AVF_APK_CACHE:-$HOME/.cache/avf-apk-build}"
mkdir -p "$cache/sdk" "$cache/gradle"
CLT=commandlinetools-linux-11076708_latest.zip
CLT_SHA256="${CLT_SHA256:-}"   # optional: set to verify the download
docker run --rm -v "$repo:/src" -v "$cache/sdk:/sdk" -v "$cache/gradle:/root/.gradle" \
  -e ANDROID_HOME=/sdk -e CLT="$CLT" -e CLT_SHA256="$CLT_SHA256" -e UID_GID="$(id -u):$(id -g)" \
  eclipse-temurin:21-jdk bash -euc '
  if [ ! -x /sdk/cmdline-tools/latest/bin/sdkmanager ]; then
    apt-get update -qq && apt-get install -y -qq --no-install-recommends unzip curl >/dev/null
    curl -fsSLo /tmp/clt.zip "https://dl.google.com/android/repository/$CLT"
    [ -z "$CLT_SHA256" ] || echo "$CLT_SHA256  /tmp/clt.zip" | sha256sum -c -
    unzip -q /tmp/clt.zip -d /tmp/clt && mkdir -p /sdk/cmdline-tools && mv /tmp/clt/cmdline-tools /sdk/cmdline-tools/latest
  fi
  yes | /sdk/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null || true
  /sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-36" "build-tools;36.0.0" >/dev/null
  cd /src/probe/app
  echo "sdk.dir=/sdk" > local.properties
  ./gradlew --no-daemon -q assembleDebug
  rm -f local.properties
  chown -R "$UID_GID" /src/probe/app/app/build /src/probe/app/.gradle 2>/dev/null || true
'
ls -la "$repo/probe/app/app/build/outputs/apk/debug/app-debug.apk"
