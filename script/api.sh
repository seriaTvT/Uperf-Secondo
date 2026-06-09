#!/system/bin/sh
#
# API Script for KernelSU WebUI
#

BASEDIR="$(dirname $(readlink -f "$0"))"
. $BASEDIR/pathinfo.sh

CONFIG_FILE="$MODULE_PATH/module_config.json"

# Initialize config if not exists
if [ ! -f "$CONFIG_FILE" ]; then
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
fi

action="$1"
key="$2"
value="$3"

case "$action" in
    "status")
        running=false
        if pidof uperf >/dev/null; then running=true; fi
        master=$(grep -o '"master_switch": \?[true|false]*' "$CONFIG_FILE" | cut -d: -f2 | tr -d ' "')
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
            awk -v key="\"$key\"" -v val="$value" '
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
            }' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
            mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            
            # Apply immediate mode switch if the key is "mode"
            if [ "$key" = "mode" ]; then
                sh "$SCRIPT_PATH/powercfg_main.sh" $(echo "$value" | tr -d '"')
            fi
            echo "success"
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
