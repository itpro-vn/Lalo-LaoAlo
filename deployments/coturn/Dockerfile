FROM coturn/coturn:4.6-alpine

# Copy default config
COPY deployments/coturn/turnserver.conf /etc/turnserver.conf

# Expose STUN/TURN ports
EXPOSE 3478/tcp 3478/udp
EXPOSE 5349/tcp 5349/udp
# Relay port range
EXPOSE 49152-65535/udp

# Health check: attempt STUN binding request
HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
  CMD turnutils_stunclient 127.0.0.1 || exit 1

ENTRYPOINT ["turnserver", "-c", "/etc/turnserver.conf"]
