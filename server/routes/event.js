const express = require('express');
const crypto = require('crypto');
const router = express.Router();
const db = require('../db');

// Event V2：客户端行为事件
const ALLOWED = ['enter', 'click', 'continue', 'drop', 'thumb_up', 'thumb_down', 'finish_navigation'];

router.post('/', (req, res) => {
  const { visitor_id, event_type, domain, conversation_id, payload } = req.body || {};
  if (!ALLOWED.includes(event_type)) return res.status(400).json({ error: 'bad event_type: ' + event_type });
  db.prepare(
    'INSERT INTO events (id, visitor_id, conversation_id, event_type, domain, payload, created_at) VALUES (?,?,?,?,?,?,?)'
  ).run(crypto.randomUUID(), visitor_id || null, conversation_id || null, event_type, domain || null,
    JSON.stringify(payload || {}), Date.now());
  res.json({ ok: true });
});

module.exports = router;
