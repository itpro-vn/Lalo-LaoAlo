FROM nginx:1.27-alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy gateway config
COPY deployments/nginx/nginx.conf /etc/nginx/nginx.conf

# Create SSL directory
RUN mkdir -p /etc/nginx/ssl

EXPOSE 80 443 8888

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD wget -q --spider http://localhost:8888/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
