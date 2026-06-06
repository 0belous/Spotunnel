#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/spotunnel-setup.log"
MODE="host"
PREPARE_ONLY=0
UPDATE_ONLY=0
OPUS_BITRATE="${OPUS_BITRATE:-}"
SETUP_SCRIPT_VERSION="1"

usage() {
    cat << 'EOF'
Usage: setup.sh [--mode host|docker] [--bitrate 128k] [--prepare-only] [--update]

--mode host|docker    Select host install or Docker image preparation.
--bitrate VALUE       Set the Opus bitrate used by FFmpeg.
--prepare-only        Skip service startup and only prepare files.
--update              Skip dependency install and only refresh runtime configuration.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --bitrate)
            OPUS_BITRATE="$2"
            shift 2
            ;;
        --prepare-only|--no-start)
            PREPARE_ONLY=1
            shift
            ;;
        --update)
            UPDATE_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ "$MODE" != "host" && "$MODE" != "docker" ]]; then
    echo "Invalid mode: $MODE" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

task_log() {
    local state="$1"
    local label="$2"
    printf '[%s] %-4s %s\n' "$(date '+%H:%M:%S')" "$state" "$label"
}

run_task() {
    local label="$1"
    shift
    task_log "RUN" "$label"
    if "$@" >> "$LOG_FILE" 2>&1; then
        task_log "DONE" "$label"
    else
        task_log "FAIL" "$label (see $LOG_FILE)"
        exit 1
    fi
}

run_task_cmd() {
    local label="$1"
    local command="$2"
    task_log "RUN" "$label"
    if bash -o pipefail -c "$command" >> "$LOG_FILE" 2>&1; then
        task_log "DONE" "$label"
    else
        task_log "FAIL" "$label (see $LOG_FILE)"
        exit 1
    fi
}

resolve_opus_bitrate() {
    if [[ -n "$OPUS_BITRATE" ]]; then
        return
    fi

    if [[ -t 0 ]]; then
        read -rp "Enter opus bitrate (e.g. 96k, 128k, 192k) [default: 128k]: " USER_BITRATE
        OPUS_BITRATE="${USER_BITRATE:-128k}"
    else
        OPUS_BITRATE="128k"
    fi
}

read_version_file() {
    local version_file="$(dirname "$(readlink -f "$0")")/version.txt"

    if [[ ! -f "$version_file" ]]; then
        echo "1"
        return
    fi

    local file_version
    file_version="$(tr -dc '0-9' < "$version_file" | head -c 1)"
    if [[ -z "$file_version" ]]; then
        echo "1"
    else
        echo "$file_version"
    fi
}

validate_update_mode() {
    if [[ "$UPDATE_ONLY" -eq 0 ]]; then
        return
    fi

    local current_version
    current_version="$(read_version_file)"

    if [[ "$current_version" != "$SETUP_SCRIPT_VERSION" ]]; then
        task_log "INFO" "Update requested, but version.txt=$current_version and script version=$SETUP_SCRIPT_VERSION differ. Running full setup."
        UPDATE_ONLY=0
    else
        task_log "INFO" "Update mode enabled (version.txt=$current_version matches script version)."
    fi
}

write_pulseaudio_config() {
    run_task "Create PulseAudio config directory" mkdir -p /home/spotifydaemon/.config/pulse
    task_log "RUN" "Write PulseAudio default config"
    cat << 'EOF' > /home/spotifydaemon/.config/pulse/default.pa
load-module module-native-protocol-unix
load-module module-always-sink
load-module module-null-sink sink_name=SpotifySink sink_properties=device.description="Virtual_Spotify_Sink"
set-default-sink SpotifySink
EOF
    task_log "DONE" "Write PulseAudio default config"
    run_task "Set spotifydaemon config ownership" chown -R spotifydaemon:spotifydaemon /home/spotifydaemon/.config
}

write_spotify_runner() {
    TMP_SPOTIFY_RUN="$(mktemp)"
    task_log "RUN" "Write spotify runner script"
    cat > "$TMP_SPOTIFY_RUN" << EOF
#!/bin/bash
set -u

DISPLAY_VAL=":99"
export DISPLAY=\$DISPLAY_VAL
MEM_GUARD_LIMIT_MB="\${SPOTIFY_MAX_RSS_MB:-1200}"
LISTENER_RESTART_SECONDS="\${SPOTIFY_ZERO_LISTENER_RESTART_SEC:-300}"
SPOTIFY_RESTART_COOLDOWN="\${SPOTIFY_RESTART_COOLDOWN_SEC:-90}"

log() {
    echo "[spotunnel] \$*"
}

wait_for_icecast() {
    local tries=0
    while ! curl -fsS http://localhost:8000/status-json.xsl > /dev/null 2>&1; do
        tries=\$((tries + 1))
        if [ \$tries -ge 30 ]; then
            return 1
        fi
        sleep 1
    done
    return 0
}

cleanup() {
    pkill -P \$\$
    pulseaudio -k 2>/dev/null
    exit
}

ensure_audio_stack() {
    if ! pulseaudio --check 2>/dev/null; then
        pulseaudio --start --exit-idle-time=-1 > /dev/null 2>&1
        sleep 1
    fi

    if ! pactl list short sinks 2>/dev/null | grep -q '^.*SpotifySink'; then
        pactl load-module module-null-sink sink_name=SpotifySink sink_properties=device.description="Virtual_Spotify_Sink" > /dev/null 2>&1 || true
        sleep 1
    fi

    pactl set-default-sink SpotifySink > /dev/null 2>&1 || true
}

start_ffmpeg() {
    wait_for_icecast || return 1
    ensure_audio_stack
    if ! pactl list short sources 2>/dev/null | grep -q '^.*SpotifySink\.monitor'; then
        return 1
    fi
    ffmpeg -nostdin -y -f pulse -i SpotifySink.monitor -c:a libmp3lame -b:a ${OPUS_BITRATE} -content_type audio/mpeg -f mp3 icecast://source:hackme@localhost:8000/spotify.mp3 > /tmp/ffmpeg.log 2>&1 &
    FFMPEG_PID=\$!
}

start_spotify() {
    spotify --disable-gpu --disable-software-rasterizer --no-sandbox --no-zygote --force-device-scale-factor=1.28 > /dev/null 2>&1 &
    SPOTIFY_PID=\$!
    SPOTIFY_START_TIME=\$(date +%s)
}

request_system_reboot() {
    if [ ! -x /usr/local/bin/spotunnel-system-reboot.sh ]; then
        return 1
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo -n /usr/local/bin/spotunnel-system-reboot.sh >/dev/null 2>&1
    else
        /usr/local/bin/spotunnel-system-reboot.sh >/dev/null 2>&1
    fi
}

spotify_rss_mb() {
    local spotify_pid="\$1"
    local rss_kb
    rss_kb=\$(ps -o rss= -p "\$spotify_pid" 2>/dev/null | tr -d '[:space:]')
    if [ -z "\$rss_kb" ]; then
        echo "0"
        return
    fi
    echo \$((rss_kb / 1024))
}

can_restart_spotify() {
    local now
    now=\$(date +%s)
    if [ \$LAST_SPOTIFY_RESTART_TIME -eq 0 ]; then
        return 0
    fi
    if [ \$(( now - LAST_SPOTIFY_RESTART_TIME )) -lt \$SPOTIFY_RESTART_COOLDOWN ]; then
        return 1
    fi
    return 0
}

restart_ffmpeg() {
    if [ -n "\${FFMPEG_PID}" ] && kill -0 \$FFMPEG_PID 2>/dev/null; then
        kill \$FFMPEG_PID 2>/dev/null || true
        wait \$FFMPEG_PID 2>/dev/null || true
    fi
    FFMPEG_PID=""
    start_ffmpeg || true
}

restart_spotify() {
    local now
    now=\$(date +%s)

    if [ -n "\${SPOTIFY_PID}" ] && kill -0 \$SPOTIFY_PID 2>/dev/null; then
        kill \$SPOTIFY_PID 2>/dev/null || true
        wait \$SPOTIFY_PID 2>/dev/null || true
    fi
    SPOTIFY_PID=""
    restart_ffmpeg
    start_spotify
    LAST_SPOTIFY_RESTART_TIME=\$now
}

trap cleanup SIGINT SIGTERM
ensure_audio_stack
if ! pgrep -f "Xvfb \$DISPLAY_VAL" > /dev/null; then
    Xvfb \$DISPLAY_VAL -screen 0 720x1280x24 -ac +extension RANDR &
    sleep 2
    x11vnc -display \$DISPLAY_VAL -forever -nopw -shared -rfbport 5900 -bg -noshm -geometry 720x1280 &
    DISPLAY=\$DISPLAY_VAL matchbox-window-manager &
    sleep 1
fi

SPOTIFY_PID=""
FFMPEG_PID=""
ZERO_LISTENER_START_TIME=0
LAST_SPOTIFY_RESTART_TIME=0
start_spotify
QR_SHOWN=0
while true; do
    ensure_audio_stack
    if [ -n "\${SPOTIFY_PID}" ] && kill -0 \$SPOTIFY_PID 2>/dev/null; then
        SPOTIFY_RSS_MB=\$(spotify_rss_mb "\$SPOTIFY_PID")
        if [ "\$SPOTIFY_RSS_MB" -ge "\$MEM_GUARD_LIMIT_MB" ]; then
            if can_restart_spotify; then
                log "Spotify RSS \${SPOTIFY_RSS_MB}MB crossed limit \${MEM_GUARD_LIMIT_MB}MB; restarting Spotify"
                restart_spotify
            fi
        fi
    fi

    LISTENER_COUNT=\$(curl -fsS http://localhost:8000/status-json.xsl 2>/dev/null | grep -o '"listeners":[0-9]*' | grep -o '[0-9]*' || echo "0")
    echo "Listener count: \${LISTENER_COUNT}"
    if [ "\$LISTENER_COUNT" = "0" ]; then
        if [ \$ZERO_LISTENER_START_TIME -eq 0 ]; then
            ZERO_LISTENER_START_TIME=\$(date +%s)
        else
            CURRENT_TIME=\$(date +%s)
            if [ \$(( CURRENT_TIME - ZERO_LISTENER_START_TIME )) -ge \$LISTENER_RESTART_SECONDS ]; then
                if can_restart_spotify; then
                    log "Zero listeners for \${LISTENER_RESTART_SECONDS}s; restarting Spotify pipeline"
                    restart_spotify
                fi

                if ! request_system_reboot; then
                    log "Reboot helper unavailable/failed; recovered by process restart only"
                fi

                ZERO_LISTENER_START_TIME=\$(date +%s)
            fi
        fi
    else
        ZERO_LISTENER_START_TIME=0
    fi

    if [ -z "\${FFMPEG_PID}" ] || ! kill -0 \$FFMPEG_PID 2>/dev/null; then
        start_ffmpeg || true
    fi
    if [ \$QR_SHOWN -eq 0 ] && pgrep -x "spotify" > /dev/null; then
        scrot -z -o /tmp/spotify_headless.png > /dev/null 2>&1
        QR_URL=\$(zbarimg -q --raw /tmp/spotify_headless.png 2>/dev/null)
        if [ ! -z "\$QR_URL" ]; then
            clear
            qrencode -t ansiutf8 "\$QR_URL"
            echo "\$QR_URL"
            QR_SHOWN=1
        fi
    fi
    sleep 3
done
EOF
    task_log "DONE" "Write spotify runner script"
    run_task "Install spotify runner script" install -o spotifydaemon -g spotifydaemon -m 755 "$TMP_SPOTIFY_RUN" /usr/local/bin/spotify-run.sh
    run_task "Clean temporary runner script" rm -f "$TMP_SPOTIFY_RUN"
}

write_systemd_service() {
    TMP_SPOTIFY_SERVICE="$(mktemp)"
    task_log "RUN" "Write systemd service"
    cat << 'EOF' > "$TMP_SPOTIFY_SERVICE"
[Unit]
Wants=network-online.target icecast2.service
After=network-online.target icecast2.service
[Service]
ExecStart=/usr/bin/dbus-run-session /usr/local/bin/spotify-run.sh
Restart=always
RestartSec=5
User=spotifydaemon
Environment=HOME=/home/spotifydaemon
WorkingDirectory=/home/spotifydaemon
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    task_log "DONE" "Write systemd service"

    run_task "Install systemd service" install -o root -g root -m 644 "$TMP_SPOTIFY_SERVICE" /etc/systemd/system/spotify-headless.service
    run_task "Cleanup temporary files" rm -f "$TMP_SPOTIFY_SERVICE"
}

write_reboot_helper() {
    task_log "RUN" "Write system reboot helper"
    cat << 'EOF' > /usr/local/bin/spotunnel-system-reboot.sh
#!/bin/bash
set -euo pipefail

logger -t spotunnel "Zero-listener threshold reached; rebooting host"
sync
systemctl reboot --force --force || reboot -f
EOF
    task_log "DONE" "Write system reboot helper"
    run_task "Install system reboot helper" chmod 755 /usr/local/bin/spotunnel-system-reboot.sh
}

write_reboot_sudoers() {
    task_log "RUN" "Write reboot sudoers rule"
    cat << 'EOF' > /etc/sudoers.d/spotunnel-reboot
spotifydaemon ALL=(root) NOPASSWD: /usr/local/bin/spotunnel-system-reboot.sh
EOF
    task_log "DONE" "Write reboot sudoers rule"
    run_task "Set sudoers permissions" chmod 440 /etc/sudoers.d/spotunnel-reboot
}

write_docker_entrypoint() {
    task_log "RUN" "Write Docker runtime helper"
    cat << 'EOF' > /usr/local/bin/spotunnel-docker-run.sh
#!/bin/bash
set -euo pipefail

ICECAST_LOG="/var/log/icecast2.log"
mkdir -p "$(dirname "$ICECAST_LOG")"

icecast2 -b -c /etc/icecast2/icecast.xml >> "$ICECAST_LOG" 2>&1 &
ICECAST_PID="$!"
SPOTIFY_PID=""

cleanup() {
    if [ -n "$SPOTIFY_PID" ]; then
        kill "$SPOTIFY_PID" 2>/dev/null || true
        wait "$SPOTIFY_PID" 2>/dev/null || true
    fi
    kill "$ICECAST_PID" 2>/dev/null || true
    wait "$ICECAST_PID" 2>/dev/null || true
}

trap cleanup INT TERM

set +e
if command -v runuser >/dev/null 2>&1; then
    runuser -u spotifydaemon -- env HOME=/home/spotifydaemon dbus-run-session /usr/local/bin/spotify-run.sh &
else
    su -s /bin/bash -c 'HOME=/home/spotifydaemon dbus-run-session /usr/local/bin/spotify-run.sh' spotifydaemon &
fi
SPOTIFY_PID="$!"
set +e
wait "$SPOTIFY_PID"
EXIT_CODE="$?"
set -e

cleanup
exit "$EXIT_CODE"
EOF
    task_log "DONE" "Write Docker runtime helper"
    run_task "Install Docker runtime helper" chmod 755 /usr/local/bin/spotunnel-docker-run.sh
}

install_common_dependencies() {
    run_task "APT update" apt-get update
    run_task "APT upgrade" apt-get upgrade -y
    run_task_cmd "Preconfigure icecast2" "echo 'icecast2 icecast2/icecast-setup boolean false' | debconf-set-selections"
    # Added x11vnc and matchbox-window-manager
    run_task "Install dependencies" apt-get install -y --reinstall curl gnupg sudo xvfb scrot zbar-tools qrencode pulseaudio ffmpeg icecast2 dbus-x11 unzip zip x11vnc matchbox-window-manager
    run_task_cmd "Install Spotify signing key" "curl -sS https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg"
    run_task_cmd "Add Spotify repository" "echo 'deb https://repository.spotify.com stable non-free' > /etc/apt/sources.list.d/spotify.list"
    run_task "APT update" apt-get update
    run_task "Install Spotify" apt-get install -y --reinstall spotify-client
    run_task_cmd "Patch Spotify (SpotX)" "bash <(curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh) -f"
    run_task_cmd "Create spotifydaemon user" "useradd -m -G audio,video spotifydaemon 2>/dev/null || true"
    run_task_cmd "Ensure spotifydaemon groups" "usermod -aG audio,video spotifydaemon 2>/dev/null || true"
}

start_host_services() {
    run_task "Reload systemd daemon" systemctl daemon-reload
    run_task "Enable services" systemctl enable icecast2 spotify-headless
    run_task "Restart services" systemctl restart icecast2 spotify-headless
}

restart_docker_processes() {
    run_task_cmd "Restart running processes" "pkill -f spotify-run.sh || true; pkill spotify || true; pkill ffmpeg || true"
}

print_host_next_steps() {
    IP_ADDR=$(hostname -I | awk '{print $1}')
    echo ""
    echo "1. View your Spotify Login QR code by running:"
    echo "   journalctl -u spotify-headless -n 200 -f -o cat"
    echo ""
    echo "2. Open VLC Network Stream (or any media player) and connect here:"
    echo "   http://${IP_ADDR}:8000/spotify.mp3"
    echo ""
    echo "3. Optionally connect to VNC on port 5900"
    echo ""
}

print_docker_next_steps() {
    echo ""
    echo "1. View your Spotify Login QR code by running:"
    echo "   docker logs -f <container-name>"
    echo ""
    echo "2. Open VLC Network Stream (or any media player) and connect here:"
    echo "   http://<host-ip>:8000/spotify.ogg"
    echo ""
}

export DEBIAN_FRONTEND=noninteractive
task_log "INFO" "Spotunnel setup started in $MODE mode. Log: $LOG_FILE"
validate_update_mode
resolve_opus_bitrate

if [[ "$UPDATE_ONLY" -eq 0 ]]; then
    install_common_dependencies
else
    task_log "INFO" "Skipping dependency and Spotify install in update mode."
fi

write_pulseaudio_config
write_spotify_runner

if [[ "$MODE" == "host" ]]; then
    write_systemd_service
    write_reboot_helper
    write_reboot_sudoers
fi

if [[ "$MODE" == "docker" ]]; then
    write_docker_entrypoint
fi

if [[ "$PREPARE_ONLY" -eq 0 ]]; then
    if [[ "$MODE" == "host" ]]; then
        start_host_services
        print_host_next_steps
    else
        print_docker_next_steps
    fi
fi

echo "Setup log file: ${LOG_FILE}"