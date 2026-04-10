FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src/ ./src/
RUN mkdir -p /app/uploads
EXPOSE 3001
CMD ["node", "--require", "./src/tracing.js", "src/index.js"]
