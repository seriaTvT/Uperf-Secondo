#!/system/bin/sh
#
# API Script for KernelSU WebUI
#

BASEDIR="$(dirname $(readlink -f "$0"))"
. $BASEDIR/pathinfo.sh

CONFIG_FILE="$MODULE_PATH/module_config.json"
LOCK_DIR="$CONFIG_FILE.lock"

write_default_config() {
    cat > "$CONFIG_FILE" <<EOF
{
  "master_switch": true,
  "mode": "balance",
  "enable_mtk_fpsgo_hack": true,
  "disable_system_thermal": true,
  "enable_asoul_opt": true,
  "disable_gpu_thermal": true
}
EOF
    chmod 644 "$CONFIG_FILE"
}

# A config is considered valid only if it carries the keys we expect.
# A corrupt file (e.g. empty or stray newlines from an old concurrent write)
# must be recreated, otherwise it can never self-heal.
config_is_valid() {
    [ -s "$CONFIG_FILE" ] && grep -q '"master_switch"' "$CONFIG_FILE"
}

# Atomic, busybox-safe lock. mkdir is atomic across processes, so rapid
# concurrent set_config calls (e.g. toggling several switches at once) are
# serialized instead of clobbering a shared temp file.
acquire_lock() {
    i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 50 ] && break   # ~5s safety timeout
        sleep 0.1 2>/dev/null || sleep 1
    done
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
}

# Initialize / self-heal config
if ! config_is_valid; then
    write_default_config
fi

action="$1"
key="$2"
value="$3"

case "$action" in
    "status")
        running=false
        if pidof uperf >/dev/null; then running=true; fi
        master=$(grep '"master_switch"' "$CONFIG_FILE" | awk -F':' '{print $2}' | tr -d ' ",')
        mode=$(cat "$USER_PATH/cur_powermode.txt" 2>/dev/null || echo "balance")
        platform=$(getprop ro.board.platform)
        
        cat <<EOF
{
  "running": $running,
  "master_switch": ${master:-true},
  "mode": "$mode",
  "platform": "$platform"
}
EOF
        ;;
    "get_config")
        cat "$CONFIG_FILE"
        ;;
    "set_config")
        if [ -n "$key" ] && [ -n "$value" ]; then
            # Ensure quotes for string values (not true/false) in case shell stripped them
            case "$value" in
                true|false|\"*) val="$value" ;;
                *) val="\"$value\"" ;;
            esac

            acquire_lock

            # Self-heal before editing so a corrupt file can't propagate.
            config_is_valid || write_default_config

            tmp="${CONFIG_FILE}.$$.tmp"
            awk -v key="\"$key\"" -v val="$val" '
            {
              if ($1 == key ":") {
                if ($0 ~ /,$/) {
                  print "  " key ": " val ","
                } else {
                  print "  " key ": " val
                }
              } else {
                print $0
              }
            }' "$CONFIG_FILE" > "$tmp"

            # Only commit if the rewrite produced a sane file; never overwrite
            # the config with empty/garbage output.
            if [ -s "$tmp" ] && grep -q '"master_switch"' "$tmp"; then
                mv "$tmp" "$CONFIG_FILE"
                chmod 644 "$CONFIG_FILE"
                result="success"
            else
                rm -f "$tmp"
                result="error: rewrite failed"
            fi

            release_lock

            # Apply the change immediately so the WebUI never requires a reboot.
            # All paths route through initsvc.sh (backgrounded to keep the UI
            # responsive) so they share its lock and never race on sysfs.
            if [ "$result" = "success" ]; then
                case "$key" in
                    mode)
                        sh "$SCRIPT_PATH/powercfg_main.sh" "$(echo "$value" | tr -d '"')" >/dev/null 2>&1
                        ;;
                    master_switch)
                        # Start/stop the whole service.
                        nohup sh "$SCRIPT_PATH/initsvc.sh" >/dev/null 2>&1 &
                        ;;
                    enable_asoul_opt)
                        # Just the A-SOUL daemon — no need to bounce uperf.
                        nohup sh "$SCRIPT_PATH/initsvc.sh" asoul >/dev/null 2>&1 &
                        ;;
                    disable_system_thermal|disable_gpu_thermal|enable_mtk_fpsgo_hack)
                        # Re-apply the per-platform tweaks that read these keys.
                        nohup sh "$SCRIPT_PATH/initsvc.sh" tweaks >/dev/null 2>&1 &
                        ;;
                esac
            fi
            echo "$result"
        else
            echo "error: missing key or value"
        fi
        ;;
    "set_mode")
        if [ -n "$key" ]; then
            sh "$SCRIPT_PATH/powercfg_main.sh" "$key"
            echo "success"
        else
            echo "error: missing mode"
        fi
        ;;
    *)
        echo "unknown action: $action"
        ;;
esac
