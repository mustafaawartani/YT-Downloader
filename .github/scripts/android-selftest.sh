#!/usr/bin/env bash
# Runs the app's built-in self-test (MainActivity.runSelfTest) on a booted emulator:
# yt-dlp init, --version, link info, MP3 download through FFmpeg, save to Downloads.
set -u
APK="$1"
PKG=com.mustafa.toolbox

# Local test clip served to the emulator (10.0.2.2 = the host).
mkdir -p /tmp/media
ffmpeg -loglevel error -y -f lavfi -i testsrc=duration=5:size=320x240:rate=15 \
  -f lavfi -i sine=frequency=440:duration=5 -shortest -c:v libx264 -c:a aac /tmp/media/clip.mp4
nohup python3 -m http.server 8000 --directory /tmp/media >/tmp/http.log 2>&1 &

adb install -r "$APK" || exit 1

run_test() {
  local url="$1" label="$2"
  adb shell am force-stop "$PKG"
  adb logcat -c
  adb shell am start -n "$PKG/.MainActivity" --es toolbox_selftest "$url" >/dev/null
  for _ in $(seq 1 120); do
    adb logcat -d -s Toolbox:* | grep -q "TOOLBOX_SELFTEST DONE" && break
    sleep 5
  done
  echo "================ self-test: $label ================"
  adb logcat -d -s Toolbox:* | head -150
  adb logcat -d -s Toolbox:* | grep -q "TOOLBOX_SELFTEST DONE pass=5 fail=0"
}

run_test "http://10.0.2.2:8000/clip.mp4" "local clip"; LOCAL=$?
run_test "https://www.youtube.com/watch?v=jNQXAC9IVRw" "YouTube"; YT=$?
echo "local=$LOCAL youtube=$YT"
[ "$YT" -eq 0 ] || echo "::warning::YouTube self-test failed (YouTube often blocks CI servers; see log above)"
exit "$LOCAL"
