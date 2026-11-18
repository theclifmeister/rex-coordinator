# shellcheck shell=bash
# Sourced by doctor.sh and hooks-handlers/session-start.sh: the tsk version
# check. Plain bash, no jq, no set -e, one `tsk --version` call.

TSK_MIN=0.14.1
# shellcheck disable=SC2034 # read by the scripts that source this
TSK_FIX="update with 'tsk update', or install it from https://gettsk.sh"

# tsk_version_check: 0 = tsk >= TSK_MIN, 1 = not installed, 2 = older,
# 3 = version unparsable (unknown: callers warn, never fail).
# Sets TSK_VER to what `tsk --version` reported (first line).
tsk_version_check() {
  TSK_VER=
  command -v tsk >/dev/null 2>&1 || return 1
  TSK_VER=$(tsk --version 2>/dev/null | head -n1)
  local v ma mi pa wma wmi wpa
  v=$(printf '%s\n' "$TSK_VER" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  [ -n "$v" ] || return 3
  IFS=. read -r ma mi pa <<<"$v"
  IFS=. read -r wma wmi wpa <<<"$TSK_MIN"
  # 10# keeps leading zeros from reading as octal.
  ma=$((10#$ma)) mi=$((10#$mi)) pa=$((10#$pa))
  if [ "$ma" -ne "$wma" ]; then
    [ "$ma" -gt "$wma" ] || return 2
  elif [ "$mi" -ne "$wmi" ]; then
    [ "$mi" -gt "$wmi" ] || return 2
  else
    [ "$pa" -ge "$wpa" ] || return 2
  fi
  return 0
}
