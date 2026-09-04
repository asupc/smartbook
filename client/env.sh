#!/usr/bin/env bash
# Shared build environment for smartbook-client on this machine.
# Usage: source env.sh  (then run flutter commands)
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
export JAVA_HOME="$HOME/devtools/jdk-17"
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
export ANDROID_SDK_ROOT="$LOCALAPPDATA/Android/Sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
