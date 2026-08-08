'use strict';

const express = require('express');
const { build, sitemap, robots } = require('../pages');

const router = express.Router();

router.get('/about', (req, res) => {
  const html = build('about');
  if (!html) return res.status(404).send('Not found');
  res.type('html').send(html);
});

router.get('/compare', (req, res) => {
  const html = build('compare');
  if (!html) return res.status(404).send('Not found');
  res.type('html').send(html);
});

router.get('/scenarios', (req, res) => {
  const html = build('scenarios');
  if (!html) return res.status(404).send('Not found');
  res.type('html').send(html);
});

router.get('/faq', (req, res) => {
  const html = build('faq');
  if (!html) return res.status(404).send('Not found');
  res.type('html').send(html);
});

router.get('/community', (req, res) => {
  const html = build('community');
  if (!html) return res.status(404).send('Not found');
  res.type('html').send(html);
});

router.get('/sitemap.xml', (req, res) => {
  res.type('application/xml').send(sitemap());
});

router.get('/robots.txt', (req, res) => {
  res.type('text/plain').send(robots());
});

module.exports = router;
