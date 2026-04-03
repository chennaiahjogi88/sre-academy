FROM nginx:1.24-alpine
LABEL org.opencontainers.image.title="demo-site"
LABEL org.opencontainers.image.description="Static demo website served by nginx"
LABEL org.opencontainers.image.license="MIT"

RUN rm -rf /usr/share/nginx/html/*
COPY files/ /usr/share/nginx/html/

# Fix permissions so nginx can read the files
RUN chmod -R 755 /usr/share/nginx/html/

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qS --spider http://localhost:80/ || exit 1
CMD ["nginx", "-g", "daemon off;"]

