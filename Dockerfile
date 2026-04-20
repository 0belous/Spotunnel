FROM debian:13

ARG OPUS_BITRATE=128k
ENV DEBIAN_FRONTEND=noninteractive
ENV OPUS_BITRATE=${OPUS_BITRATE}

WORKDIR /opt/spotunnel

COPY setup.sh /opt/spotunnel/setup.sh
RUN chmod +x /opt/spotunnel/setup.sh && /opt/spotunnel/setup.sh --mode docker --bitrate "${OPUS_BITRATE}" --prepare-only

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/spotunnel-docker-run.sh"]