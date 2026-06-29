#!/vendor/bin/sh
#
# Copyright (C) 2021-2022 Matt Yang
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Applies the current config. Runs at boot (via service.sh, no argument) and
# again whenever the WebUI changes a setting (via api.sh), so changes take
# effect immediately instead of only after a reboot. Scope argument:
#   (none)  full init: master switch, all tweaks, start uperf, A-SOUL daemon
#   tweaks  re-apply the per-platform tweaks without bouncing uperf
#   asoul   start/stop the A-SOUL daemon only (fast path for its toggle)

BASEDIR="$(dirname $(readlink -f "$0"))"
. $BASEDIR/pathinfo.sh
. $BASEDIR/libcommon.sh
. $BASEDIR/libuperf.sh

# create busybox symlinks
$BIN_PATH/busybox/busybox --install -s $BIN_PATH/busybox

SCOPE="$1"

# Serialize concurrent runs (boot vs. WebUI live re-apply) so two pipelines
# never fight over the uperf/AsoulOpt processes or bind-mounts at once.
INIT_LOCK="/data/local/tmp/uperf_initsvc.lock"
i=0
while ! mkdir "$INIT_LOCK" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && break   # ~10s safety timeout against a stale lock
    sleep 0.1 2>/dev/null || sleep 1
done
trap 'rmdir "$INIT_LOCK" 2>/dev/null' EXIT

wait_until_login

ASOUL_DIR="/data/adb/modules/asoul_affinity_opt"

read_cfg() {
    [ -f "$MODULE_CONFIG" ] || return
    grep "\"$1\"" "$MODULE_CONFIG" | awk -F: '{print $2}' | tr -d ' ",'
}

# A-SOUL thread affinity daemon. Honor the WebUI toggle both ways: the module
# "disable" flag persists the choice across reboots, and we start/stop the
# running daemon so the change is effective right now.
apply_asoul() {
    [ -d "$ASOUL_DIR" ] || return
    if [ "$(read_cfg enable_asoul_opt)" = "false" ]; then
        touch "$ASOUL_DIR/disable"
        killall -9 AsoulOpt 2>/dev/null
    else
        rm -f "$ASOUL_DIR/disable"
        if ! pidof AsoulOpt >/dev/null 2>&1 && [ -x "$ASOUL_DIR/AsoulOpt" ]; then
            nohup "$ASOUL_DIR/AsoulOpt" >/dev/null 2>&1 &
        fi
    fi
}

# Fast path: only touch the A-SOUL daemon.
if [ "$SCOPE" = "asoul" ]; then
    apply_asoul
    exit 0
fi

# Global off: stop everything and apply nothing. Previously uperf was started
# unconditionally here, so the master switch had no effect at boot.
if [ "$(read_cfg master_switch)" = "false" ]; then
    uperf_stop
    [ -d "$ASOUL_DIR" ] && touch "$ASOUL_DIR/disable"
    killall -9 AsoulOpt 2>/dev/null
    rm -f "$FLAG_PATH/need_recuser"
    exit 0
fi

sh $SCRIPT_PATH/powercfg_once.sh
sh $SCRIPT_PATH/platform_special.sh
sh $SCRIPT_PATH/miui_migt.sh

# A feature-toggle re-apply only needs the tweaks above; leave uperf and the
# A-SOUL daemon running untouched.
if [ "$SCOPE" = "tweaks" ]; then
    exit 0
fi

uperf_start
apply_asoul

# Remove bootloop protection flag after successful initialization
rm -f "$FLAG_PATH/need_recuser"
