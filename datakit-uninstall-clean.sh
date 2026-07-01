#!/usr/bin/env bash
# =============================================================================
# DataKit host uninstall — residual cleanup
# -----------------------------------------------------------------------------
# Strategy:
#   1. Let DataKit uninstall itself first:  `datakit service -U`
#      (recent DataKit versions already clean up part of the environment).
#   2. Then check, step by step, what is LEFT BEHIND and remove only that.
#      Every step first checks whether its target still exists; if DataKit's
#      own `-U` already removed it, the step is skipped (no redundant work).
#
# What it cleans up (only if still present):
#   - Services: datakit and dk_upgrader (the upgrade manager installed by default)
#   - Install dirs: /usr/local/datakit, /usr/local/dk_upgrader
#   - Log dirs:     /var/log/datakit,  /var/log/dk_upgrader
#   - Symlinks:     /usr/local/bin|/usr/local/sbin|/sbin|/usr/sbin|/usr/bin /datakit
#   - Host-level APM auto-instrumentation residue (only if it was enabled at
#     install time): the datakit line inside /etc/ld.so.preload is removed
#     surgically (the file itself is NOT deleted); /etc/docker/daemon.json and
#     PHP conf.d/*.ini are only detected and reported (manual restore advised).
#
# Scope / supported platforms:
#   - Linux only (Ubuntu / RHEL / CentOS family), x86_64 or arm64.
#   - Init system auto-detected: systemd (preferred) or SysV init.
#   - NOT for macOS or Windows.
#
# Usage:
#   sudo bash datakit-uninstall-clean.sh            # run
#   sudo bash datakit-uninstall-clean.sh --dry-run  # show actions only, change nothing
#
# Note: paths follow the official DataKit install layout (Linux install dir
#       /usr/local/datakit). If you customized DK_INSTALL_DIR at install time,
#       edit the variables below.
# =============================================================================
set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# ---- Platform guard --------------------------------------------------------
OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
  echo "ERROR: this script supports Linux only (Ubuntu / RHEL / CentOS family)."
  echo "       Detected OS: $OS — aborting."
  exit 1
fi
ARCH="$(uname -m)"

# ---- Privilege -------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: must run as root (or install sudo)."
    exit 1
  fi
fi

# ---- Init system detection -------------------------------------------------
INIT="unknown"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT="systemd"
elif [ -d /etc/init.d ]; then
  INIT="sysv"
fi

# ---- Paths (override here if you used a custom install dir) -----------------
DK_DIR="/usr/local/datakit"
UP_DIR="/usr/local/dk_upgrader"
DK_LOG="/var/log/datakit"
UP_LOG="/var/log/dk_upgrader"
SYMLINKS=(
  /usr/local/bin/datakit
  /usr/local/sbin/datakit
  /sbin/datakit
  /usr/sbin/datakit
  /usr/bin/datakit
)

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

echo "==================================================================="
echo " DataKit host uninstall - residual cleanup"
echo " OS=$OS  ARCH=$ARCH  init=$INIT  dry-run=$DRY_RUN"
echo "==================================================================="

# --- 1. Let DataKit uninstall itself first ----------------------------------
echo ">>> [1/6] Run DataKit's own uninstall (datakit service -U)"
if command -v datakit >/dev/null 2>&1; then
  run "$SUDO datakit service -T 2>/dev/null || true"   # stop
  run "$SUDO datakit service -U 2>/dev/null || true"   # uninstall
else
  echo "    'datakit' command not found - skipping (will clean residue by files)."
fi

# 1b. Stop processes that survived `service -U`.
#     A host process is terminated. A CONTAINERIZED process belongs to a
#     Kubernetes DaemonSet / container and is NOT killed here - it must be
#     removed via kubectl (host uninstall cannot remove a Pod).
for proc in datakit dk_upgrader; do
  for pid in $(pgrep -x "$proc" 2>/dev/null); do
    if grep -qiE "kubepods|containerd|/docker/|crio" "/proc/$pid/cgroup" 2>/dev/null; then
      echo "    $proc pid $pid is CONTAINERIZED (K8s DaemonSet / container) - NOT killed."
      echo "      -> Remove it via Kubernetes instead:"
      echo "           kubectl delete namespace datakit"
      echo "           kubectl delete clusterrole datakit; kubectl delete clusterrolebinding datakit"
    else
      echo "    $proc pid $pid is a host process - terminating (SIGTERM)"
      run "$SUDO kill -TERM $pid 2>/dev/null || true"
      [ "$DRY_RUN" -eq 0 ] && sleep 3
      if kill -0 "$pid" 2>/dev/null; then
        echo "    pid $pid still alive - SIGKILL"
        run "$SUDO kill -KILL $pid 2>/dev/null || true"
      fi
    fi
  done
done

# --- 2. Service units: remove ONLY if still present -------------------------
echo ">>> [2/6] Service units (datakit / dk_upgrader)"
for svc in datakit dk_upgrader; do
  found=0
  if [ "$INIT" = "systemd" ]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      found=1
      run "$SUDO systemctl stop $svc 2>/dev/null || true"
      run "$SUDO systemctl disable $svc 2>/dev/null || true"
    fi
    for unit in \
      "/etc/systemd/system/$svc.service" \
      "/usr/lib/systemd/system/$svc.service" \
      "/lib/systemd/system/$svc.service"; do
      if [ -e "$unit" ]; then found=1; run "$SUDO rm -f \"$unit\""; fi
    done
  fi
  # SysV / upstart fallback
  if [ -e "/etc/init.d/$svc" ];    then found=1; run "$SUDO rm -f \"/etc/init.d/$svc\""; fi
  if [ -e "/etc/init/$svc.conf" ]; then found=1; run "$SUDO rm -f \"/etc/init/$svc.conf\""; fi

  if [ "$found" -eq 0 ]; then
    echo "    $svc: not present (already handled) - skipped."
  fi
done
if [ "$INIT" = "systemd" ]; then
  run "$SUDO systemctl daemon-reload 2>/dev/null || true"
  run "$SUDO systemctl reset-failed 2>/dev/null || true"
fi

# --- 3. Symlinks: remove ONLY if still present ------------------------------
echo ">>> [3/6] Binary symlinks"
sym_found=0
for ln in "${SYMLINKS[@]}"; do
  if [ -L "$ln" ] || [ -e "$ln" ]; then
    sym_found=1
    run "$SUDO rm -f \"$ln\""
  fi
done
[ "$sym_found" -eq 0 ] && echo "    no symlinks present (already handled) - skipped."

# --- 4. Host-level APM auto-instrumentation residue -------------------------
#     Only present if DK_APM_INSTRUMENTATION_ENABLED was used at install time.
echo ">>> [4/6] APM host-injection residue (ld.so.preload / docker / php)"
apm_found=0

# 4a. /etc/ld.so.preload - remove ONLY the datakit line (never delete the file)
PRELOAD="/etc/ld.so.preload"
if [ -f "$PRELOAD" ] && grep -qE "datakit|apm_inject" "$PRELOAD" 2>/dev/null; then
  apm_found=1
  echo "    $PRELOAD contains a datakit injection line - backing up and removing that line"
  run "$SUDO cp -a \"$PRELOAD\" \"${PRELOAD}.dkbak.\$(date +%s)\""
  run "$SUDO sed -i.tmp '/datakit/d;/apm_inject/d' \"$PRELOAD\" && $SUDO rm -f \"${PRELOAD}.tmp\""
fi

# 4b. /etc/docker/daemon.json - high risk: detect & advise only, do NOT auto-edit
DJSON="/etc/docker/daemon.json"
if [ -f "$DJSON" ] && grep -qiE "datakit|dk-?runc|apm_inject" "$DJSON" 2>/dev/null; then
  apm_found=1
  echo "    WARNING: $DJSON contains a datakit runc injection."
  echo "             Not auto-edited (a bad edit can break Docker). To restore:"
  echo "               ls -t ${DJSON}.bak.* 2>/dev/null | head -1   # backup left by installer"
  echo "               sudo cp <that backup> $DJSON && sudo systemctl restart docker"
  echo "             Or manually remove the datakit 'runtimes'/'default-runtime' entry, then restart docker."
fi

# 4c. PHP conf.d/*.ini - detect & advise restore from installer's *.backup
if ls /etc/php/*/*/conf.d/*datakit*.ini >/dev/null 2>&1 \
   || grep -rlsiE "apm_inject|datakit" /etc/php/*/*/conf.d/ >/dev/null 2>&1; then
  apm_found=1
  echo "    WARNING: PHP conf.d may contain a datakit injection."
  echo "             Review and restore the matching ini from the *.backup file in the same dir."
fi

[ "$apm_found" -eq 0 ] && echo "    no APM host-injection residue found - skipped."

# --- 5. Install & log directories: remove ONLY if still present -------------
echo ">>> [5/6] Install & log directories"
dir_found=0
for d in "$DK_DIR" "$UP_DIR" "$DK_LOG" "$UP_LOG"; do
  if [ -d "$d" ]; then
    dir_found=1
    run "$SUDO rm -rf \"$d\""
  fi
done
[ "$dir_found" -eq 0 ] && echo "    no install/log dirs present (already handled) - skipped."

# --- 6. Verify residue ------------------------------------------------------
echo ">>> [6/6] Verify residue"
residual=0
check() { if [ -e "$1" ] || [ -L "$1" ]; then echo "    STILL PRESENT: $1"; residual=1; fi; }
check "$DK_DIR"; check "$UP_DIR"; check "$DK_LOG"; check "$UP_LOG"
for ln in "${SYMLINKS[@]}"; do check "$ln"; done
for svc in datakit dk_upgrader; do
  check "/etc/systemd/system/$svc.service"
  check "/etc/init.d/$svc"
done
if pgrep -x datakit >/dev/null 2>&1; then
  echo "    WARNING: datakit process still running."
  echo "             If this is a K8s node, it is likely the DaemonSet Pod -"
  echo "             remove it with: kubectl delete namespace datakit; kubectl delete clusterrole datakit; kubectl delete clusterrolebinding datakit"
  residual=1
fi
if [ -f /etc/ld.so.preload ] && grep -qE "datakit|apm_inject" /etc/ld.so.preload 2>/dev/null; then
  echo "    WARNING: /etc/ld.so.preload still contains a datakit injection line"; residual=1
fi

echo "-------------------------------------------------------------------"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry-run finished: the actions above were NOT executed."
elif [ "$residual" -eq 0 ]; then
  echo "DONE: no residue detected."
else
  echo "WARNING: some residue remains (see above). This may be due to a custom"
  echo "         install path or insufficient privileges - please handle manually."
fi

# --- Optional: static hosts entries added by the installer ------------------
# If a static IP + domain mapping was used at install time (e.g. PrivateLink /
# offline install), the installer may have appended an entry to /etc/hosts.
# This is NOT removed automatically (risk). Review manually:
echo "Note: if a static hosts mapping was used at install time, review /etc/hosts:"
echo "      grep -nEi 'openway|dataway|truewatch' /etc/hosts"
