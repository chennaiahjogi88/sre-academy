const client = require('prom-client');

// Create a Registry
const register = new client.Registry();

// Add default Node.js metrics
client.collectDefaultMetrics({ register });

// Custom metrics
const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

const activeUsersGauge = new client.Gauge({
  name: 'active_websocket_users',
  help: 'Number of currently connected WebSocket users',
  registers: [register],
});

const loginAttemptsTotal = new client.Counter({
  name: 'login_attempts_total',
  help: 'Total login attempts',
  labelNames: ['result'],  // 'success' | 'failure'
  registers: [register],
});

const classViewsTotal = new client.Counter({
  name: 'class_views_total',
  help: 'Total class PPT views',
  labelNames: ['class_id'],
  registers: [register],
});

const announcementsTotal = new client.Counter({
  name: 'announcements_sent_total',
  help: 'Total announcements sent by admins',
  registers: [register],
});

const fileUploadsTotal = new client.Counter({
  name: 'recording_uploads_total',
  help: 'Total recording file uploads',
  labelNames: ['status'],
  registers: [register],
});

module.exports = {
  register,
  httpRequestsTotal,
  httpRequestDuration,
  activeUsersGauge,
  loginAttemptsTotal,
  classViewsTotal,
  announcementsTotal,
  fileUploadsTotal,
};
