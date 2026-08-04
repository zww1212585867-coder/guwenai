const express = require('express');
const crypto = require('crypto');
const router = express.Router();
const db = require('../db');

// 用户反馈：⭐评分 + 文字
router.post('/', (req, res) => {
  const { visitor_id, domain, conversation_id, score, content } = req.body || {};
  if (!visitor_id) return res.status(400).json({ error: 'visitor_id required' });
  db.prepare(
    'INSERT INTO feedback (id, visitor_id, domain, conversation_id, score, content, created_at) VALUES (?,?,?,?,?,?,?)'
  ).run(crypto.randomUUID(), visitor_id, domain || null, conversation_id || null, score ?? null, content || null, Date.now());
  res.json({ ok: true });
});

module.exports = router;
