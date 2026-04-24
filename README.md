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

**Tested on:**
- Docker
- Promox
- WSL

Running on bare metal is possible but only recommended with a fresh install due to variability in snowflake systems.

## Setup

**Container / Host install:**

1. Create a Debian 13 LXC container.

> If you are not running in a container you might have to run `sudo su` before the setup script.

2. Run the setup script:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0belous/Spotunnel/refs/heads/main/setup.sh)
```

> If you already have spotunnel installed, running the setup script again will update it/reinstall to fix errors

3. When prompted, choose a restreaming bitrate (Default: `128k`)
4. Check the service logs to get the Spotify login QR code/URL:

```bash
journalctl -u spotify-headless -n 200 -f -o cat
```

5. Log in, then select Spotunnel in Spotify Connect.
6. Open the stream in [Transistor](https://f-droid.org/en/packages/org.y20k.transistor):

```
http://<server-ip>:8000/spotify.ogg
```

If you want access outside your local network, publish or tunnel this URL yourself.

**Docker:**

1. Clone this repository:

```bash
git clone https://github.com/0belous/Spotunnel.git
```

2. Build the image:

```bash
docker build -t spotunnel .
```

3. Run the container and expose Icecast on port 8000:

```bash
docker run -d --name spotunnel -p 8000:8000 spotunnel
```

4. Watch the container logs for the Spotify login QR code:

```bash
docker logs -f spotunnel
```

5. Log in, then select Spotunnel in Spotify Connect.
6. Open the stream in VLC or another player:

```text
http://<host-ip>:8000/spotify.ogg
```

If you want a different Opus bitrate, pass `--build-arg OPUS_BITRATE=192k` to `docker build`.

## Notes

- The service user is `spotifydaemon`.
- Startup command: `/usr/local/bin/spotify-run.sh`
- Service name: `spotify-headless`
- The Docker container entrypoint is `/usr/local/bin/spotunnel-docker-run.sh`