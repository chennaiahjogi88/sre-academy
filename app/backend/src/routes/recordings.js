const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const db = require('../db');
const { authenticate, requireAdmin } = require('../middleware/auth');
const { fileUploadsTotal } = require('../metrics');
const { trace, SpanStatusCode } = require('@opentelemetry/api');

const tracer = trace.getTracer('sre-platform-backend');

const router = express.Router();
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, '../../../uploads');

// Ensure upload dir exists
try {
  if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });
} catch (e) {
  console.warn('Warning: could not create upload directory:', UPLOAD_DIR, '-', e.message);
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, UPLOAD_DIR),
  filename: (req, file, cb) => {
    const unique = Date.now() + '-' + Math.round(Math.random() * 1e9);
    cb(null, unique + path.extname(file.originalname));
  },
});

const upload = multer({
  storage,
  limits: { fileSize: parseInt(process.env.MAX_FILE_SIZE_MB || '500') * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const allowed = ['.mp4', '.webm', '.mkv', '.avi', '.mov'];
    if (allowed.includes(path.extname(file.originalname).toLowerCase())) cb(null, true);
    else cb(new Error('Only video files allowed'));
  },
});

// GET /api/recordings
router.get('/', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT r.*, u.name as uploader_name
       FROM recordings r
       LEFT JOIN users u ON r.uploaded_by = u.id
       WHERE r.is_published = TRUE
       ORDER BY r.class_id, r.created_at DESC`
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch recordings' });
  }
});

// POST /api/recordings/upload (admin only)
router.post('/upload', authenticate, requireAdmin, upload.single('recording'), async (req, res) => {
  return tracer.startActiveSpan('recording.upload', async (span) => {
    try {
      if (!req.file) {
        span.setAttributes({ 'upload.result': 'no_file' });
        span.setStatus({ code: SpanStatusCode.ERROR, message: 'No file uploaded' });
        span.end();
        return res.status(400).json({ error: 'No file uploaded' });
      }
      const { class_id, title, description } = req.body;
      if (!class_id || !title) {
        span.setAttributes({ 'upload.result': 'missing_fields' });
        span.setStatus({ code: SpanStatusCode.ERROR, message: 'class_id and title required' });
        span.end();
        return res.status(400).json({ error: 'class_id and title required' });
      }

      span.setAttributes({
        'recording.class_id': class_id,
        'recording.title': title,
        'file.size_bytes': req.file.size,
        'file.original_name': req.file.originalname,
        'user.id': req.user.id,
      });

      const result = await db.query(
        `INSERT INTO recordings (class_id, title, description, filename, original_filename, file_size, uploaded_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
        [class_id, title, description || null, req.file.filename, req.file.originalname, req.file.size, req.user.id]
      );

      fileUploadsTotal.inc({ status: 'success' });
      span.setAttributes({ 'upload.result': 'success', 'recording.id': result.rows[0].id });
      span.setStatus({ code: SpanStatusCode.OK });
      span.end();
      res.json(result.rows[0]);
    } catch (err) {
      fileUploadsTotal.inc({ status: 'failure' });
      span.setAttributes({ 'upload.result': 'error' });
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.end();
      console.error('Upload error:', err);
      res.status(500).json({ error: 'Upload failed' });
    }
  });
});

// GET /api/recordings/stream/:filename
router.get('/stream/:filename', authenticate, (req, res) => {
  const span = tracer.startSpan('recording.stream');
  const filePath = path.join(UPLOAD_DIR, path.basename(req.params.filename));
  if (!fs.existsSync(filePath)) {
    span.setAttributes({ 'stream.result': 'not_found' });
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'File not found' });
    span.end();
    return res.status(404).json({ error: 'File not found' });
  }

  const stat = fs.statSync(filePath);
  const fileSize = stat.size;
  const range = req.headers.range;

  span.setAttributes({
    'file.name': req.params.filename,
    'file.size_bytes': fileSize,
    'stream.range_request': !!range,
  });

  if (range) {
    const parts = range.replace(/bytes=/, '').split('-');
    const start = parseInt(parts[0], 10);
    const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
    const chunkSize = end - start + 1;
    span.setAttributes({ 'stream.chunk_size_bytes': chunkSize, 'stream.range_start': start, 'stream.range_end': end });
    const file = fs.createReadStream(filePath, { start, end });
    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${fileSize}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': chunkSize,
      'Content-Type': 'video/mp4',
    });
    file.on('end', () => span.end());
    file.on('error', (e) => { span.setStatus({ code: SpanStatusCode.ERROR, message: e.message }); span.end(); });
    file.pipe(res);
  } else {
    res.writeHead(200, { 'Content-Length': fileSize, 'Content-Type': 'video/mp4' });
    const file = fs.createReadStream(filePath);
    file.on('end', () => span.end());
    file.on('error', (e) => { span.setStatus({ code: SpanStatusCode.ERROR, message: e.message }); span.end(); });
    file.pipe(res);
  }
});

// DELETE /api/recordings/:id (admin)
router.delete('/:id', authenticate, requireAdmin, async (req, res) => {
  try {
    const rec = await db.query('SELECT filename FROM recordings WHERE id = $1', [req.params.id]);
    if (rec.rows.length === 0) return res.status(404).json({ error: 'Not found' });

    const filePath = path.join(UPLOAD_DIR, rec.rows[0].filename);
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);

    await db.query('DELETE FROM recordings WHERE id = $1', [req.params.id]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Delete failed' });
  }
});

module.exports = router;
