# Spotunnel

Spotunnel is a Debian setup script that runs Spotify desktop headlessly and restreams audio to a portable device.

## Purpose

Most android adblocking methods have been mitigated by spotify or are unreliable/slow however desktop adblocking has been so far unaffected, this script bridges the gap and lets you listen to desktop spotify on your phone.

## How It Works

Spotunnel configures a container environment with this pipeline:

`Spotify desktop -> FFmpeg (Opus) -> Icecast -> your phone/player`

You are responsible for remote access (for example Tailscale, Cloudflare Tunnel, or port forwarding).

## Requirements

- Debian 13 container
- At least 1 vCPU, 1 GB RAM, and 5 GB storage
- A reachable network path to the Icecast stream URL

## Setup

**Proxmox:**

1. Create a Debian 13 LXC container.
2. Run the setup script:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0belous/Spotunnel/refs/heads/main/setup.sh)
```

3. When prompted, choose an Opus bitrate (default: `128k`).
4. Check the service logs to get the Spotify login QR code/URL:

```bash
journalctl -u spotify-headless
```

5. Log in, then select Spotunnel in Spotify Connect.
6. Open the stream in VLC (or any compatible player):

```
http://<server-ip>:8000/spotify.ogg
```

If you want access outside your local network, publish or tunnel this URL yourself.

**Docker:**

- Coming soon

## Notes

- The service user is `spotifydaemon`.
- Startup command: `/usr/local/bin/spotify-run.sh`
- Service name: `spotify-headless`