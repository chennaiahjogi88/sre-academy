const express = require('express');
const db = require('../db');
const { authenticate, requireAdmin } = require('../middleware/auth');
const { announcementsTotal } = require('../metrics');

const router = express.Router();

// GET /api/announcements — active announcements
router.get('/', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT a.*, u.name as creator_name
       FROM announcements a
       LEFT JOIN users u ON a.created_by = u.id
       WHERE a.is_active = TRUE AND (a.expires_at IS NULL OR a.expires_at > NOW())
       ORDER BY a.created_at DESC LIMIT 20`
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch announcements' });
  }
});

// POST /api/announcements (admin)
router.post('/', authenticate, requireAdmin, async (req, res) => {
  try {
    const { title, message, type, expires_at } = req.body;
    if (!title || !message) return res.status(400).json({ error: 'title and message required' });

    const result = await db.query(
      `INSERT INTO announcements (title, message, type, created_by, expires_at)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [title, message, type || 'info', req.user.id, expires_at || null]
    );

    announcementsTotal.inc();

    // Emit to all WS clients via global io instance
    if (global.io) {
      global.io.emit('announcement', {
        id: result.rows[0].id,
        title,
        message,
        type: type || 'info',
        created_at: result.rows[0].created_at,
        creator_name: req.user.name,
      });
    }

    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to create announcement' });
  }
});

// DELETE /api/announcements/:id (admin)
router.delete('/:id', authenticate, requireAdmin, async (req, res) => {
  try {
    await db.query('UPDATE announcements SET is_active = FALSE WHERE id = $1', [req.params.id]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Delete failed' });
  }
});

module.exports = router;
