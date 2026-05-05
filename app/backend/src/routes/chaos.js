const express = require('express');

const router = express.Router();

const state = {
  enabled: false,
  errorRate: 50,
  totalInjected: 0,
};

// Applied in index.js before routes so injected 500s flow through the metrics middleware
function chaosMiddleware(req, res, next) {
  if (!state.enabled) return next();
  // Never sabotage the control endpoints themselves
  if (req.path.startsWith('/chaos') || req.path === '/metrics' || req.path === '/health') return next();

  if (Math.random() * 100 < state.errorRate) {
    state.totalInjected++;
    return res.status(500).json({
      error: 'Chaos injected — simulated server error',
      chaos: true,
    });
  }
  next();
}

// POST /chaos/enable  — body: { "errorRate": 0-100 }
router.post('/enable', (req, res) => {
  const rate = Number(req.body?.errorRate ?? 50);
  state.enabled = true;
  state.errorRate = Math.min(100, Math.max(0, rate));
  state.totalInjected = 0;
  res.json({ message: `Chaos enabled at ${state.errorRate}% error rate`, ...state });
});

// POST /chaos/disable
router.post('/disable', (req, res) => {
  state.enabled = false;
  res.json({ message: 'Chaos disabled', ...state });
});

// GET /chaos/status
router.get('/status', (req, res) => {
  res.json(state);
});

module.exports = { router, chaosMiddleware };
