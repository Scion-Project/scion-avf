# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared adb plumbing for probe/run-on-device.sh and bench/run-on-device.sh.
# Source it; it defines functions only. Works with bash 3.2 (stock macOS). Non-interactive by design: nothing
# prompts, every adb call has stdin closed, every wait has a deadline, and the
# device is put back the way it was found when the script exits (even on ^C).
#
#   avf_pick_device [SERIAL]       choose the target, fail fast if none/ambiguous
#   avf_setup <apk>                install, grant, exemption, keep screen on
#   avf_push <local> <remote-dir>  push a file into the app's external files dir
#   avf_run_one <tag> <timeout_s> [am-start extras...]
#                                  run the app once, pull <tag>-* into $OUT
#   avf_teardown                   (also runs from the EXIT trap)
#
# Globals the caller may set before avf_setup: OUT (results dir), KEEP_GRANTS=1.

AVF_PKG=io.github.dylanneve1.avfprobe
AVF_DATA="/sdcard/Android/data/$AVF_PKG/files"
# Minimum hidden-API exemption: the @hide custom-image builder, and the one
# @hide setter that attaches it to a VirtualMachineConfig. Each entry is a
# prefix of a dex member signature; entries are separated by ','.
# (Verified on the Android 16 emulator: ':' doesn't work, ',' does.)
AVF_EXEMPT='Landroid/system/virtualmachine/VirtualMachineCustomImageConfig$Builder;,Landroid/system/virtualmachine/VirtualMachineConfig$Builder;->setCustomImageConfig('

ADB=(adb)
AVF_SETUP_DONE=0
AVF_PREV_EXEMPT=""
AVF_PREV_STAYON=""

# timeout(1) is missing on stock macOS: use coreutils' gtimeout, else perl's alarm.
avf_timeout() {
  local s="$1"; shift
  if command -v timeout >/dev/null; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null; then gtimeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; fi
}

die() { echo "error: $1" >&2; exit "${2:-1}"; }
log() { echo "== $*"; }

# adb shell with stdin closed (an open stdin makes adb swallow the caller's input
# and, over some transports, hang) and CR stripped from the output.
sh_() { "${ADB[@]}" shell "$@" </dev/null | tr -d '\r'; }
# Like sh_ but keeps the exit status of the remote command (adb >= 1.0.40).
sh_rc() { "${ADB[@]}" shell "$@" </dev/null; }

# Single-quotes each argument for the REMOTE shell: `adb shell a b c` re-joins its
# arguments with spaces and the phone's shell splits them again, so an argument
# like "console=hvc0 panic=-1" would otherwise arrive as two.
sq() {
  local a
  for a in "$@"; do printf "'%s' " "$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"; done
}

avf_pick_device() {
  command -v adb >/dev/null || die "adb not found in PATH" 3
  local want="${1:-${ANDROID_SERIAL:-}}"
  if [[ -n "$want" ]]; then
    ADB=(adb -s "$want")
  else
    local devs
    devs=($(adb devices </dev/null | awk 'NR>1 && $2=="device" {print $1}'))   # bash 3.2: no mapfile
    case ${#devs[@]} in
      0) adb devices </dev/null >&2; die "no adb device in state 'device' (unlock the phone and accept the USB-debugging prompt)" 3 ;;
      1) ADB=(adb -s "${devs[0]}") ;;
      *) printf 'attached: %s\n' "${devs[@]}" >&2; die "several devices attached: pass -s SERIAL" 2 ;;
    esac
  fi
  avf_timeout 30 "${ADB[@]}" wait-for-device </dev/null || die "device did not come online within 30 s" 3
  local state; state="$("${ADB[@]}" get-state </dev/null 2>&1 | tr -d '\r')"
  [[ "$state" == device ]] || die "device state is '$state', expected 'device'" 3
  log "device: $(sh_ getprop ro.product.model) ($("${ADB[@]}" get-serialno </dev/null | tr -d '\r')), Android $(sh_ getprop ro.build.version.release), $(sh_ getprop ro.build.fingerprint)"
}

avf_setup() {
  local apk="$1"
  [[ -f "$apk" ]] || die "build the app first: (cd probe/app && ./gradlew assembleDebug)   [missing $apk]"
  mkdir -p "$OUT"
  AVF_PREV_EXEMPT="$(sh_ settings get global hidden_api_blacklist_exemptions)"
  AVF_PREV_STAYON="$(sh_ settings get global stay_on_while_plugged_in)"
  trap avf_teardown EXIT
  trap 'echo "interrupted" >&2; exit 130' INT TERM
  AVF_SETUP_DONE=1

  log "install + grants"
  "${ADB[@]}" install -r -g "$apk" </dev/null >/dev/null || die "adb install failed"
  sh_rc pm grant "$AVF_PKG" android.permission.MANAGE_VIRTUAL_MACHINE </dev/null \
    || die "pm grant MANAGE_VIRTUAL_MACHINE failed (is this a user build with USB debugging authorised?)"
  sh_rc pm grant "$AVF_PKG" android.permission.USE_CUSTOM_VIRTUAL_MACHINE </dev/null \
    || die "pm grant USE_CUSTOM_VIRTUAL_MACHINE failed"

  log "hidden-API exemption (global; reverted at exit)"
  [[ "$AVF_PREV_EXEMPT" == null || -z "$AVF_PREV_EXEMPT" ]] || echo "note: an exemption list was already set: $AVF_PREV_EXEMPT"
  sh_rc settings put global hidden_api_blacklist_exemptions "'$AVF_EXEMPT'" </dev/null

  # The probe runs in the foreground activity; a sleeping phone freezes it.
  log "keeping the screen awake while plugged in (reverted at exit)"
  sh_rc settings put global stay_on_while_plugged_in 7 </dev/null || true
  sh_rc input keyevent KEYCODE_WAKEUP </dev/null || true
  sh_rc wm dismiss-keyguard </dev/null || true
  sh_rc mkdir -p "$AVF_DATA" </dev/null
}

avf_teardown() {
  [[ "$AVF_SETUP_DONE" == 1 ]] || return 0
  AVF_SETUP_DONE=0
  set +e
  if [[ "$AVF_PREV_EXEMPT" == null || -z "$AVF_PREV_EXEMPT" ]]; then
    sh_rc settings delete global hidden_api_blacklist_exemptions </dev/null >/dev/null
  else
    sh_rc settings put global hidden_api_blacklist_exemptions "'$AVF_PREV_EXEMPT'" </dev/null
  fi
  echo "== hidden_api_blacklist_exemptions restored to: ${AVF_PREV_EXEMPT:-null}"
  if [[ -n "$AVF_PREV_STAYON" && "$AVF_PREV_STAYON" != null ]]; then
    sh_rc settings put global stay_on_while_plugged_in "$AVF_PREV_STAYON" </dev/null
  else
    sh_rc settings delete global stay_on_while_plugged_in </dev/null >/dev/null
  fi
  sh_rc am force-stop "$AVF_PKG" </dev/null
  if [[ "${KEEP_GRANTS:-0}" == 0 ]]; then
    sh_rc pm revoke "$AVF_PKG" android.permission.MANAGE_VIRTUAL_MACHINE </dev/null
    sh_rc pm revoke "$AVF_PKG" android.permission.USE_CUSTOM_VIRTUAL_MACHINE </dev/null
    echo "== grants revoked (--keep-grants keeps them)"
  fi
}

# avf_push <local-file> <remote-subdir-of-files-dir>
avf_push() {
  [[ -f "$1" ]] || die "missing $1 (build it first: see docs/AVF-BENCH.md)"
  sh_rc mkdir -p "$AVF_DATA/$2" </dev/null
  "${ADB[@]}" push "$1" "$AVF_DATA/$2/" </dev/null >/dev/null || die "adb push $1 failed"
}

# avf_run_one <tag> <timeout_s> [extras...]
# Starts the app with --es tag <tag> and the given `am start` extras, waits for
# <tag>-result.json (written last by the app), then pulls everything for the
# tag into $OUT. Returns 0 if a result.json came back, 1 otherwise.
avf_run_one() {
  local tag="$1" tmo="$2"; shift 2
  local res="$AVF_DATA/$tag-result.json"
  log "run: $tag"
  sh_rc "rm -f $AVF_DATA/$tag-*" </dev/null
  sh_rc am force-stop "$AVF_PKG" </dev/null          # fresh process: picks up the exemption
  "${ADB[@]}" logcat -c </dev/null || true
  sh_rc input keyevent KEYCODE_WAKEUP </dev/null || true
  sh_rc "am start -W -n $AVF_PKG/.MainActivity $(sq --ez autorun true --es tag "$tag" --el timeout_s "$tmo" "$@")" </dev/null >/dev/null \
    || echo "warning: am start returned non-zero" >&2

  local deadline=$(( $(date +%s) + tmo + 90 )) t0 died=0
  t0=$(date +%s)
  until [[ "$(sh_ "test -f $res && echo y")" == y ]]; do
    if (( $(date +%s) >= deadline )); then echo "  $tag: no result.json within $((tmo + 90)) s" >&2; break; fi
    if (( $(date +%s) - t0 > 15 )) && [[ -z "$(sh_ pidof "$AVF_PKG")" ]]; then
      sleep 2   # one more look: the app may have just written the file and exited
      [[ "$(sh_ "test -f $res && echo y")" == y ]] || { echo "  $tag: app process died without a result" >&2; died=1; break; }
    fi
    sleep 2
  done
  local f
  for f in report.txt console.txt vmlog.txt result.json; do
    "${ADB[@]}" pull "$AVF_DATA/$tag-$f" "$OUT/$tag-$f" </dev/null >/dev/null 2>&1 || true
  done
  "${ADB[@]}" logcat -d </dev/null > "$OUT/$tag-logcat.txt" 2>/dev/null || true
  # virtmgr logs the full crosvm command line; keep the AVF-related lines.
  grep -iE 'virtmgr|virtualizationservice|crosvm|AvfProbe|hiddenapi|avc:.*(crosvm|virt)' \
    "$OUT/$tag-logcat.txt" > "$OUT/$tag-logcat-avf.txt" 2>/dev/null || true
  rm -f "$OUT/$tag-logcat.txt"
  if [[ -f "$OUT/$tag-result.json" ]]; then
    echo "  $tag: $(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("VERDICT:", r["verdict"], r.get("detail",""))' "$OUT/$tag-result.json" 2>/dev/null || grep -m1 '"verdict"' "$OUT/$tag-result.json")"
    return 0
  fi
  [[ $died == 1 ]] && echo "  see $OUT/$tag-logcat-avf.txt" >&2
  return 1
}
