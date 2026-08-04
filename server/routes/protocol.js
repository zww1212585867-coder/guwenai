const express = require('express');
const router = express.Router();
const db = require('../db');

// 当前生效的 Protocol 版本
router.get('/', (req, res) => {
  const row = db.prepare('SELECT version, created_at FROM protocol_versions WHERE active=1').get();
  res.json(row || { version: 'none' });
});

module.exports = router;
