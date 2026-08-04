const express = require('express');
const router = express.Router();
const db = require('../db');

// 首页推荐领域（来自受控大类字典 domain_dict）
router.get('/', (req, res) => {
  const rows = db.prepare(
    'SELECT domain, label_zh, description, sort FROM domain_dict WHERE active=1 ORDER BY sort'
  ).all();
  res.json(rows.map((r) => ({ domain: r.domain, label: r.label_zh, description: r.description })));
});

module.exports = router;
