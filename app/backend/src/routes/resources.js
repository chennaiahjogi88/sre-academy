const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const { authenticate, requireAdmin } = require('../middleware/auth');

const router = express.Router();

const BASE_UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, '../../../uploads');
const RESOURCES_DIR = path.join(BASE_UPLOAD_DIR, 'resources');

try {
  if (!fs.existsSync(RESOURCES_DIR)) fs.mkdirSync(RESOURCES_DIR, { recursive: true });
} catch (e) {
  console.warn('Warning: could not create resources directory:', e.message);
}

const ALLOWED_EXTENSIONS = ['.pdf', '.ppt', '.pptx', '.html', '.doc', '.docx', '.txt', '.md'];

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, RESOURCES_DIR),
  filename: (req, file, cb) => {
    const safe = file.originalname.replace(/[^a-zA-Z0-9._-]/g, '_');
    cb(null, Date.now() + '-' + safe);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 100 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    if (ALLOWED_EXTENSIONS.includes(path.extname(file.originalname).toLowerCase())) cb(null, true);
    else cb(new Error('File type not allowed. Accepted: PDF, PPT, PPTX, HTML, DOC, DOCX, TXT, MD'));
  },
});

// GET /api/resources — list uploaded resource files (authenticated)
router.get('/', authenticate, (req, res) => {
  try {
    const files = fs.readdirSync(RESOURCES_DIR)
      .filter(f => !f.startsWith('.') && !f.startsWith('_'))
      .map(filename => {
        const stat = fs.statSync(path.join(RESOURCES_DIR, filename));
        const originalName = filename.replace(/^\d+-/, '');
        return {
          filename,
          original_name: originalName,
          size: stat.size,
          created_at: stat.birthtime,
          ext: path.extname(filename).toLowerCase(),
        };
      })
      .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    res.json(files);
  } catch (err) {
    res.status(500).json({ error: 'Failed to list resources' });
  }
});

// POST /api/resources/upload — upload a resource file (admin only)
router.post('/upload', authenticate, requireAdmin, upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  const originalName = req.file.filename.replace(/^\d+-/, '');
  res.json({
    filename: req.file.filename,
    original_name: originalName,
    size: req.file.size,
    ext: path.extname(req.file.originalname).toLowerCase(),
  });
});

// GET /api/resources/download/:filename — download a resource file (authenticated)
router.get('/download/:filename', authenticate, (req, res) => {
  const filename = path.basename(req.params.filename);
  const filePath = path.join(RESOURCES_DIR, filename);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'File not found' });
  const originalName = filename.replace(/^\d+-/, '');
  res.download(filePath, originalName);
});

// DELETE /api/resources/:filename — delete a resource file (admin only)
router.delete('/:filename', authenticate, requireAdmin, (req, res) => {
  const filename = path.basename(req.params.filename);
  const filePath = path.join(RESOURCES_DIR, filename);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'File not found' });
  fs.unlinkSync(filePath);
  res.json({ success: true });
});

module.exports = router;
