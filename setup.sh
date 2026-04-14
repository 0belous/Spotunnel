#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
echo "icecast2 icecast2/icecast-setup boolean false" | debconf-set-selections
apt-get install -y --reinstall curl gnupg sudo xvfb scrot zbar-tools qrencode pulseaudio ffmpeg icecast2 dbus-x11 unzip zip
curl -sS https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg
echo "deb https://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list
apt-get update
apt-get install -y --reinstall spotify-client

bash <(curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh)

read -rp "Enter opus bitrate (e.g. 96k, 128k, 192k) [default: 128k]: " USER_BITRATE
OPUS_BITRATE=${USER_BITRATE:-128k}

useradd -m -G audio,video spotifydaemon 2>/dev/null || true
mkdir -p /home/spotifydaemon/.config/pulse
cat << 'EOF' > /home/spotifydaemon/.config/pulse/default.pa
load-module module-native-protocol-unix
load-module module-always-sink
load-module module-null-sink sink_name=SpotifySink sink_properties=device.description="Virtual_Spotify_Sink"
set-default-sink SpotifySink
EOF
chown -R spotifydaemon:spotifydaemon /home/spotifydaemon/.config

cat > /usr/local/bin/spotify-run.sh << EOF
#!/bin/bash
DISPLAY_VAL=":99"
export DISPLAY=\$DISPLAY_VAL
cleanup() {
    pkill -P \$\$
    pulseaudio -k 2>/dev/null
    exit
}
trap cleanup SIGINT SIGTERM
pulseaudio --start --exit-idle-time=-1
sleep 2
pactl load-module module-null-sink sink_name=SpotifySink sink_properties=device.description="Virtual_Spotify_Sink" 2>/dev/null
pactl set-default-sink SpotifySink
sleep 1
if ! pgrep -f "Xvfb \$DISPLAY_VAL" > /dev/null; then
    Xvfb \$DISPLAY_VAL -screen 0 1024x768x24 -ac +extension RANDR &
    sleep 2
fi
ffmpeg -nostdin -y \\
    -f pulse -i SpotifySink.monitor \\
    -c:a libopus -b:a $OPUS_BITRATE \\
    -content_type audio/ogg \\
    -f ogg icecast://source:hackme@localhost:8000/spotify.ogg \\
    > /tmp/ffmpeg.log 2>&1 &
sleep 2
spotify --disable-gpu --disable-software-rasterizer --no-sandbox --no-zygote > /dev/null 2>&1 &
START_TIME=\$(date +%s)
while [ \$((\$(date +%s) - START_TIME)) -lt 60 ]; do
    scrot -z -o /tmp/spotify_headless.png > /dev/null 2>&1
    QR_URL=\$(zbarimg -q --raw /tmp/spotify_headless.png 2>/dev/null)
    if [ ! -z "\$QR_URL" ]; then
        clear
        qrencode -t ansiutf8 "\$QR_URL"
        echo "\$QR_URL"
        break
    fi
    pgrep -x "spotify" > /dev/null || cleanup
    sleep 3
done
while pgrep -x "spotify" > /dev/null; do
    sleep 5
done
cleanup
EOF

chmod +x /usr/local/bin/spotify-run.sh
chown spotifydaemon:spotifydaemon /usr/local/bin/spotify-run.sh

cat << 'EOF' > /etc/systemd/system/spotify-headless.service
[Unit]
After=network.target icecast2.service
[Service]
ExecStart=/usr/bin/dbus-run-session /usr/local/bin/spotify-run.sh
Restart=always
User=spotifydaemon
Environment=HOME=/home/spotifydaemon
WorkingDirectory=/home/spotifydaemon
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable icecast2 spotify-headless
systemctl restart icecast2 spotify-headless
IP_ADDR=$(hostname -I | awk '{print $1}')
echo ""
echo "1. View your Spotify Login QR code by running:"
echo "   journalctl -u spotify-headless"
echo ""
echo "2. Open VLC Network Stream (or any media player) and connect here:"
echo "   http://${IP_ADDR}:8000/spotify.ogg"