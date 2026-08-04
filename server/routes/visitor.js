const express = require('express');
const crypto = require('crypto');
const router = express.Router();
const db = require('../db');

// 创建或获取匿名访客（不要求登录）
router.post('/', (req, res) => {
  const { visitor_id, consent_version } = req.body || {};
  const id = visitor_id || crypto.randomUUID();
  const now = Date.now();
  const existing = db.prepare('SELECT * FROM visitors WHERE visitor_id=?').get(id);
  if (!existing) {
    db.prepare(
      'INSERT INTO visitors (visitor_id, created_at, consent_version, consent_at, status) VALUES (?,?,?,?,?)'
    ).run(id, now, consent_version || null, consent_version ? now : null, 'active');
  }
  res.json({ visitor_id: id, created: !existing });
});

// 查询访客画像与行为统计
router.get('/:id', (req, res) => {
  const v = db.prepare('SELECT * FROM visitors WHERE visitor_id=?').get(req.params.id);
  if (!v) return res.status(404).json({ error: 'not found' });
  const profiles = db.prepare('SELECT * FROM cognitive_profiles WHERE visitor_id=?').all(req.params.id);
  const stats = db.prepare(
    'SELECT event_type, COUNT(*) c FROM events WHERE visitor_id=? GROUP BY event_type'
  ).all(req.params.id);
  res.json({ visitor: v, profiles, stats });
});

module.exports = router;
