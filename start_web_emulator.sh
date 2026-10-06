#!/usr/bin/env bash
# אמולטור אנדרואיד בדפדפן: אמולטור עם חלון על מסך וירטואלי (Xvfb), שרת VNC שמציג רק את מסך המכשיר
# (x11vnc), ו-websockify שמגיש את web/index.html (noVNC + מקשי מכשיר-מקשים)
# ב-http://localhost:$WEB_PORT/ — הסיסמה בכתובת: http://localhost:$WEB_PORT/#pw=<VNC_PASSWORD>.
# נקרא מ-.github/workflows/emulator.yml (שם הכתובת נחשפת החוצה ב-cloudflared), ואפשר להריץ אותו גם במחשב.
#
# משתנים (כולם אופציונליים):
#   API=19                רמת API — צריך system-images;android-$API;default;$ABI מותקן (נבדק רק 19)
#   ABI=x86
#   SCREEN=480x854        רזולוציית המכשיר
#   DENSITY=240           dpi
#   ACCEL=auto            auto = KVM כשיש /dev/kvm שאפשר לפתוח, אחרת אמולציה בתוכנה (איטית)
#   VNC_PASSWORD=...      סיסמה ל-VNC; ריק = בלי סיסמה (רק כשהכתובת אינה חשופה)
#   WEB_PORT=6080
#   WORK=$PWD/web-emulator  תיקיית העבודה (AVD, לוגים)
#   ANDROID_ID=4d6f6f7669646f73  מזהה-אנדרואיד קבוע (16 תווי hex), כדי שמזהה-המכשיר שהאפליקציה מציגה
#                         יהיה זהה בכל הפעלה (אישור משתמש 6.10.2026); ריק = מה שהאמולטור הגריל
# דורש: ANDROID_SDK_ROOT עם emulator + platform-tools, וחבילות xvfb x11vnc novnc websockify x11-utils xdotool.
set -euo pipefail

API="${API:-19}"
ABI="${ABI:-x86}"
SCREEN="${SCREEN:-480x854}"
DENSITY="${DENSITY:-240}"
ACCEL="${ACCEL:-auto}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
WEB_PORT="${WEB_PORT:-6080}"
WORK="${WORK:-$PWD/web-emulator}"
ANDROID_ID="${ANDROID_ID-4d6f6f7669646f73}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "$SDK" ] || { echo "ANDROID_SDK_ROOT is not set" >&2; exit 1; }

W="${SCREEN%x*}"
H="${SCREEN#*x}"
IMG="$SDK/system-images/android-$API/default/$ABI"
[ -d "$IMG" ] || { echo "missing system image: $IMG" >&2; exit 1; }
ADB="$SDK/platform-tools/adb"

mkdir -p "$WORK/avd/web.avd"
export ANDROID_AVD_HOME="$WORK/avd"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"

cat > "$WORK/avd/web.ini" <<EOF
avd.ini.encoding=UTF-8
path=$WORK/avd/web.avd
target=android-$API
EOF
# hw.keyboard=yes: מקשי המחשב (חצים, Enter, ספרות) מגיעים לאנדרואיד כמקשי חומרה — כמו מכשיר מקשים.
# hw.mainKeys=no: באנדרואיד מוצג סרגל חזרה/בית, כך שאפשר לעבוד גם בעכבר בלבד.
cat > "$WORK/avd/web.avd/config.ini" <<EOF
avd.ini.encoding=UTF-8
AvdId=web
avd.ini.displayname=web
abi.type=$ABI
hw.cpu.arch=$ABI
image.sysdir.1=system-images/android-$API/default/$ABI/
tag.id=default
tag.display=Default
hw.lcd.width=$W
hw.lcd.height=$H
hw.lcd.density=$DENSITY
hw.ramSize=1536
vm.heapSize=128
hw.keyboard=yes
hw.dPad=yes
hw.mainKeys=no
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.sdCard=yes
sdcard.size=512M
disk.dataPartition.size=4G
hw.gps=yes
hw.audioInput=no
hw.camera.back=none
hw.camera.front=none
showDeviceFrame=no
EOF
# חלון האמולטור בגודל אמיתי בפינה (בלי זה הוא מקטין את עצמו), ומקשים גולמיים: בלי ההגדרה הזו
# האמולטור מתרגם חלק מהמקשים (מקשי המספרים בצד) למקשים אחרים.
cat > "$WORK/avd/web.avd/emulator-user.ini" <<EOF
window.x = 0
window.y = 0
window.scale = 1.000000
EOF
cat > "$WORK/avd/web.avd/AVD.conf" <<EOF
[perAvd]
set\\enforceKeycodeForwarding=true
EOF

if [ "$ACCEL" = "auto" ]; then
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=on; else ACCEL=off; fi
fi
echo "acceleration: $ACCEL"
[ "$ACCEL" = "off" ] && echo "::warning::no KVM — software emulation, the emulator will be slow"

# מסך וירטואלי גדול מהמכשיר, כדי שהאמולטור לא יקטין את החלון; ה-VNC מציג רק את חלון המכשיר.
export DISPLAY=:1
Xvfb :1 -screen 0 "$(( W + 300 ))x$(( H + 300 ))x24" -nolisten tcp > "$WORK/xvfb.log" 2>&1 &
for _ in $(seq 1 50); do xdpyinfo -display :1 >/dev/null 2>&1 && break; sleep 0.2; done

# -writable-system: כדי לשנות את מפת-המקשים של המקלדת (למטה) — השינוי חי רק בהרצה הזו.
"$SDK/emulator/emulator" -avd web -accel "$ACCEL" -gpu swiftshader_indirect -writable-system \
  -no-audio -no-boot-anim -no-snapshot -no-metrics -netdelay none -netspeed full \
  -timezone Asia/Jerusalem -prop persist.sys.language=iw -prop persist.sys.country=IL \
  > "$WORK/emulator.log" 2>&1 &
echo $! > "$WORK/emulator.pid"
emulator_alive() { kill -0 "$(cat "$WORK/emulator.pid")" 2>/dev/null; }

# חלון המכשיר: מחכים שיופיע, וה-VNC חותך אליו (בלי סרגל הכלים של האמולטור ובלי השוליים השחורים).
GEOM=""
for _ in $(seq 1 120); do
  GEOM=$(xwininfo -root -tree 2>/dev/null | grep '"Android Emulator' | head -1 \
         | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1 || true)
  [ -n "$GEOM" ] && break
  emulator_alive || { echo "emulator exited:" >&2; tail -30 "$WORK/emulator.log" >&2; exit 1; }
  sleep 1
done
[ -n "$GEOM" ] || { echo "emulator window did not appear" >&2; exit 1; }
echo "emulator window: $GEOM"
# הפוקוס של המקלדת על חלון המכשיר (אין מנהל-חלונות שיעביר אותו).
xdotool windowfocus "$(xdotool search --name 'Android Emulator' | head -1)" 2>/dev/null || true

if [ -n "$VNC_PASSWORD" ]; then
  x11vnc -storepasswd "$VNC_PASSWORD" "$WORK/vnc.pass" >/dev/null 2>&1
  VNC_AUTH=(-rfbauth "$WORK/vnc.pass")
else
  VNC_AUTH=(-nopw)
fi
x11vnc -display :1 "${VNC_AUTH[@]}" -clip "$GEOM" -forever -shared -noxdamage -localhost \
  -rfbport 5900 -o "$WORK/x11vnc.log" -bg >/dev/null 2>&1

# הדף: noVNC של המערכת + index.html שלנו.
rm -rf "$WORK/web" && mkdir -p "$WORK/web"
cp -rL /usr/share/novnc/. "$WORK/web/"
cp "$HERE/web/index.html" "$WORK/web/index.html"
websockify --web "$WORK/web" "$WEB_PORT" localhost:5900 > "$WORK/websockify.log" 2>&1 &
echo $! > "$WORK/websockify.pid"

"$ADB" start-server >/dev/null 2>&1 || true
echo "waiting for Android to boot..."
start=$(date +%s)
limit=$([ "$ACCEL" = "on" ] && echo 600 || echo 1800)
until [ "$("$ADB" -e shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  emulator_alive || { echo "emulator exited:" >&2; tail -30 "$WORK/emulator.log" >&2; exit 1; }
  if [ $(( $(date +%s) - start )) -gt "$limit" ]; then
    echo "boot timed out after ${limit}s" >&2; tail -30 "$WORK/emulator.log" >&2; exit 1
  fi
  sleep 3
done
echo "booted in $(( $(date +%s) - start ))s"

# כוכבית וסולמית: מהמחשב '*' ו-'#' מגיעים כ-Shift+8 / Shift+3, ולכן '-' ו-'=' (אותו מקום בעברית
# ובאנגלית) ממופים ל-STAR / POUND במפת-המקשים של המקלדת של האמולטור. אחרי השינוי — הפעלה מחדש של
# ממשק אנדרואיד (לא של המכשיר), כדי שתיקרא מחדש.
remap_keys() {
  "$ADB" -e root >/dev/null 2>&1 || return 1
  sleep 2; "$ADB" -e wait-for-device
  "$ADB" -e remount >/dev/null 2>&1 || "$ADB" -e shell mount -o rw,remount /system >/dev/null 2>&1 || return 1
  "$ADB" -e shell cat /system/usr/keylayout/qwerty.kl | tr -d '\r' \
    | sed -E -e 's/^key 12 +MINUS$/key 12    STAR/' -e 's/^key 13 +EQUALS$/key 13    POUND/' > "$WORK/qwerty.kl"
  grep -q '^key 12    STAR$' "$WORK/qwerty.kl" || return 1
  "$ADB" -e push "$WORK/qwerty.kl" /system/usr/keylayout/qwerty.kl >/dev/null 2>&1 || return 1
  "$ADB" -e shell chmod 644 /system/usr/keylayout/qwerty.kl
  "$ADB" -e shell 'stop; start'
  sleep 5
  for _ in $(seq 1 80); do
    "$ADB" -e shell dumpsys window windows 2>/dev/null | grep -q 'mCurrentFocus=.*Launcher' && return 0
    sleep 3
  done
  return 1
}
if remap_keys; then echo "keys: '-' = STAR, '=' = POUND"; else echo "::warning::could not remap - and = to star / pound"; fi

# מזהה-אנדרואיד קבוע — לפני שמתקינים אפליקציה, כדי שמזהה-המכשיר שלה יהיה זהה בכל הפעלה.
if [ -n "$ANDROID_ID" ]; then
  "$ADB" -e shell settings put secure android_id "$ANDROID_ID" >/dev/null 2>&1 \
    && echo "android_id pinned" || echo "::warning::could not pin android_id"
fi

# מסך שלא נכבה, בלי מסך-נעילה, ומיקום GPS במרכז ירושלים (העברית ושעון ישראל — בפרמטרים למעלה).
"$ADB" -e shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
"$ADB" -e shell svc power stayon true >/dev/null 2>&1 || true
"$ADB" -e shell input keyevent 82 >/dev/null 2>&1 || true
"$ADB" -e emu geo fix 35.2137 31.7683 >/dev/null 2>&1 || true
xdotool windowfocus "$(xdotool search --name 'Android Emulator' | head -1)" 2>/dev/null || true
echo "web page: http://localhost:$WEB_PORT/"
