// Tracing must be initialized before any other require
require('./tracing');

require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const jwt = require('jsonwebtoken');

const { register, httpRequestsTotal, httpRequestDuration, activeUsersGauge } = require('./metrics');
const { router: chaosRouter, chaosMiddleware } = require('./routes/chaos');
const { trace, SpanStatusCode } = require('@opentelemetry/api');

const tracer = trace.getTracer('sre-platform-backend');
const authRoutes = require('./routes/auth');
const classRoutes = require('./routes/classes');
const recordingRoutes = require('./routes/recordings');
const announcementRoutes = require('./routes/announcements');
const adminRoutes = require('./routes/admin');
const resourceRoutes = require('./routes/resources');

const app = express();
const server = http.createServer(app);

// Socket.io
const io = new Server(server, {
  cors: { origin: '*', methods: ['GET', 'POST'] },
});
global.io = io;
global.wsConnectionCount = 0;

// ── Middleware ──
app.set('trust proxy', 1); // Trust ingress/nginx X-Forwarded-For header
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({ origin: '*' }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Request metrics middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const route = req.route?.path || req.path || 'unknown';
    httpRequestsTotal.inc({ method: req.method, route, status_code: res.statusCode });
    end({ method: req.method, route, status_code: res.statusCode });
  });
  next();
});

// Chaos middleware — must run after metrics so injected 500s are still counted
app.use(chaosMiddleware);

// Rate limiting — configurable via env vars for load-test environments
const RATE_WINDOW_MS = parseInt(process.env.RATE_LIMIT_WINDOW_MS || '60000');   // 1 min default
const RATE_MAX       = parseInt(process.env.RATE_LIMIT_MAX       || '1000');    // 1000 req/min/IP
const LOGIN_MAX      = parseInt(process.env.LOGIN_LIMIT_MAX      || '50');      // 50 login attempts/min/IP
const limiter = rateLimit({ windowMs: RATE_WINDOW_MS, max: RATE_MAX, standardHeaders: true, legacyHeaders: false });
const loginLimiter = rateLimit({ windowMs: RATE_WINDOW_MS, max: LOGIN_MAX, message: { error: 'Too many login attempts' } });
app.use('/api/', limiter);
app.use('/api/auth/login', loginLimiter);

// ── Routes ──
app.use('/chaos', chaosRouter);
app.use('/api/auth', authRoutes);
app.use('/api/classes', classRoutes);
app.use('/api/recordings', recordingRoutes);
app.use('/api/announcements', announcementRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/resources', resourceRoutes);

// Prometheus metrics endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString(), uptime: process.uptime() });
});

// ── WebSocket ──
io.on('connection', (socket) => {
  global.wsConnectionCount++;
  activeUsersGauge.inc();

  // Authenticate WS connection
  const token = socket.handshake.auth?.token;
  let user = null;
  if (token) {
    try {
      const decoded = jwt.verify(token, process.env.JWT_SECRET || 'dev_secret');
      user = { id: decoded.userId, name: decoded.name, role: decoded.role, email: decoded.email };
      socket.user = user;
    } catch (_) {}
  }

  // Broadcast updated active user count
  io.emit('active_users', { count: global.wsConnectionCount });

  // Client reports slide progress
  socket.on('slide_progress', async (data) => {
    if (!socket.user) return;
    const span = tracer.startSpan('ws.slide_progress');
    span.setAttributes({
      'user.id': socket.user.id,
      'user.role': socket.user.role,
      'class.id': data.class_id,
      'slide.current': data.current_slide,
      'slide.total': data.total_slides,
    });
    try {
      const db = require('./db');
      await db.query(
        `INSERT INTO class_progress (user_id, class_id, current_slide, total_slides, last_viewed)
         VALUES ($1, $2, $3, $4, NOW())
         ON CONFLICT (user_id, class_id) DO UPDATE SET current_slide=$3, total_slides=$4, last_viewed=NOW()`,
        [socket.user.id, data.class_id, data.current_slide, data.total_slides]
      );
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (e) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: e.message });
    } finally {
      span.end();
    }
  });

  // Admin broadcasts announcement
  socket.on('send_announcement', (data) => {
    if (socket.user?.role !== 'admin') return;
    const span = tracer.startSpan('ws.send_announcement');
    span.setAttributes({ 'user.id': socket.user.id, 'announcement.type': data.type || 'unknown' });
    io.emit('announcement', { ...data, creator_name: socket.user.name, created_at: new Date() });
    span.end();
  });

  socket.on('disconnect', () => {
    global.wsConnectionCount = Math.max(0, global.wsConnectionCount - 1);
    activeUsersGauge.dec();
    io.emit('active_users', { count: global.wsConnectionCount });
  });
});

// ── Start ──
// Skip binding in test environment — supertest creates its own ephemeral server.
if (process.env.NODE_ENV !== 'test') {
  const PORT = process.env.PORT || 3001;
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`SRE Platform Backend running on port ${PORT}`);
    console.log(`Prometheus metrics: http://localhost:${PORT}/metrics`);
    console.log(`Health check: http://localhost:${PORT}/health`);
  });
}

module.exports = { app, server };
