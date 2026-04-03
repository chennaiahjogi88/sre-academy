const express = require('express');
const bcrypt = require('bcryptjs');
const db = require('../db');
const { authenticate, requireAdmin } = require('../middleware/auth');

const router = express.Router();

// GET /api/admin/users
router.get('/users', authenticate, requireAdmin, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT id, email, name, role, is_active, created_at, last_login FROM users ORDER BY created_at DESC`
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch users' });
  }
});

// POST /api/admin/users — create user
router.post('/users', authenticate, requireAdmin, async (req, res) => {
  try {
    const { email, name, password, role } = req.body;
    if (!email || !name || !password) return res.status(400).json({ error: 'email, name, password required' });

    const hash = await bcrypt.hash(password, 10);
    const result = await db.query(
      `INSERT INTO users (email, name, password_hash, role) VALUES ($1, $2, $3, $4) RETURNING id, email, name, role`,
      [email.toLowerCase().trim(), name, hash, role || 'student']
    );
    res.json(result.rows[0]);
  } catch (err) {
    if (err.code === '23505') return res.status(409).json({ error: 'Email already exists' });
    res.status(500).json({ error: 'Failed to create user' });
  }
});

// PATCH /api/admin/users/:id — update role or status
router.patch('/users/:id', authenticate, requireAdmin, async (req, res) => {
  try {
    const { role, is_active } = req.body;
    const updates = [];
    const values = [];
    let idx = 1;
    if (role !== undefined) { updates.push(`role = $${idx++}`); values.push(role); }
    if (is_active !== undefined) { updates.push(`is_active = $${idx++}`); values.push(is_active); }
    if (updates.length === 0) return res.status(400).json({ error: 'Nothing to update' });

    values.push(req.params.id);
    await db.query(`UPDATE users SET ${updates.join(', ')} WHERE id = $${idx}`, values);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Update failed' });
  }
});

// GET /api/admin/stats
router.get('/stats', authenticate, requireAdmin, async (req, res) => {
  try {
    const [usersRes, activeSessionsRes, progressRes, recordingsRes, announcementsRes] = await Promise.all([
      db.query('SELECT COUNT(*) as total, SUM(CASE WHEN role=\'admin\' THEN 1 ELSE 0 END) as admins FROM users WHERE is_active=TRUE'),
      db.query('SELECT COUNT(*) as total FROM sessions WHERE revoked=FALSE AND expires_at > NOW()'),
      db.query('SELECT COUNT(DISTINCT user_id) as students, SUM(CASE WHEN completed=TRUE THEN 1 ELSE 0 END) as completions FROM class_progress'),
      db.query('SELECT COUNT(*) as total FROM recordings WHERE is_published=TRUE'),
      db.query('SELECT COUNT(*) as total FROM announcements WHERE is_active=TRUE'),
    ]);
    res.json({
      users: usersRes.rows[0],
      activeSessions: activeSessionsRes.rows[0].total,
      progress: progressRes.rows[0],
      recordings: recordingsRes.rows[0].total,
      announcements: announcementsRes.rows[0].total,
      wsConnections: global.wsConnectionCount || 0,
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch stats' });
  }
});

module.exports = router;
