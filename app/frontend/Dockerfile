# ── Stage 1: Build stage (copy static assets) ──
FROM node:20-alpine AS builder

WORKDIR /app

# Copy public assets
COPY public/ ./public/

# ── Stage 2: Production Nginx ──
FROM nginx:1.25-alpine

# Remove default nginx config
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy custom nginx config
COPY nginx/nginx.conf /etc/nginx/nginx.conf

# Copy static site files to nginx html root
COPY --from=builder /app/public/ /usr/share/nginx/html/

# Ensure correct permissions
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
