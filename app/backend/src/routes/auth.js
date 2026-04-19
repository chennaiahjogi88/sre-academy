const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const db = require('../db');
const { loginAttemptsTotal } = require('../metrics');
const { authenticate } = require('../middleware/auth');

const router = express.Router();
const JWT_SECRET = process.env.JWT_SECRET || 'dev_secret';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '24h';

// POST /api/auth/register
router.post('/register', async (req, res) => {
  try {
    const { name, email, password } = req.body;
    if (!name || !email || !password) {
      return res.status(400).json({ message: 'Name, email, and password are required' });
    }

    const existing = await db.query('SELECT id FROM users WHERE email = $1', [email.toLowerCase().trim()]);
    if (existing.rows.length > 0) {
      return res.status(409).json({ message: 'An account with that email already exists' });
    }

    const password_hash = await bcrypt.hash(password, 10);
    const insertRes = await db.query(
      `INSERT INTO users (email, password_hash, name, role)
       VALUES ($1, $2, $3, 'student') RETURNING id, email, name, role`,
      [email.toLowerCase().trim(), password_hash, name.trim()]
    );
    const user = insertRes.rows[0];

    const jti = uuidv4();
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);
    const token = jwt.sign(
      { userId: user.id, email: user.email, role: user.role, jti },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRES_IN }
    );

    await db.query(
      `INSERT INTO sessions (user_id, token_jti, ip_address, user_agent, expires_at)
       VALUES ($1, $2, $3, $4, $5)`,
      [user.id, jti, req.ip, req.get('user-agent'), expiresAt]
    );

    res.status(201).json({
      token,
      user: { id: user.id, email: user.email, name: user.name, role: user.role },
    });
  } catch (err) {
    console.error('Register error:', err);
    res.status(500).json({ message: 'Internal server error' });
  }
});

// POST /api/auth/login
router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    const userRes = await db.query(
      'SELECT id, email, name, role, password_hash, is_active FROM users WHERE email = $1',
      [email.toLowerCase().trim()]
    );

    if (userRes.rows.length === 0) {
      loginAttemptsTotal.inc({ result: 'failure' });
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const user = userRes.rows[0];
    if (!user.is_active) {
      loginAttemptsTotal.inc({ result: 'failure' });
      return res.status(401).json({ error: 'Account disabled' });
    }

    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      loginAttemptsTotal.inc({ result: 'failure' });
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    // Create JWT with jti for session tracking
    const jti = uuidv4();
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);
    const token = jwt.sign(
      { userId: user.id, email: user.email, role: user.role, jti },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRES_IN }
    );

    // Store session
    await db.query(
      `INSERT INTO sessions (user_id, token_jti, ip_address, user_agent, expires_at)
       VALUES ($1, $2, $3, $4, $5)`,
      [user.id, jti, req.ip, req.get('user-agent'), expiresAt]
    );

    // Update last_login
    await db.query('UPDATE users SET last_login = NOW() WHERE id = $1', [user.id]);

    loginAttemptsTotal.inc({ result: 'success' });

    res.json({
      token,
      user: { id: user.id, email: user.email, name: user.name, role: user.role },
    });
  } catch (err) {
    console.error('Login error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/auth/logout
router.post('/logout', authenticate, async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    const token = authHeader.split(' ')[1];
    const decoded = jwt.decode(token);

    await db.query(
      'UPDATE sessions SET revoked = TRUE WHERE token_jti = $1',
      [decoded.jti]
    );
    res.json({ message: 'Logged out successfully' });
  } catch (err) {
    res.status(500).json({ error: 'Logout failed' });
  }
});

// GET /api/auth/me
router.get('/me', authenticate, (req, res) => {
  res.json({ user: req.user });
});

module.exports = router;
