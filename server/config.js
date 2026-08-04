require('dotenv').config(); // 生产环境从 .env 读取密钥，本地不存在则忽略
const fs = require('fs');
const path = require('path');
const yaml = require('yaml');

// 加载 config.yaml，并替换 ${ENV_VAR} 为环境变量
function loadConfig() {
  const cfgPath = path.join(__dirname, '..', 'config.yaml');
  let raw = fs.readFileSync(cfgPath, 'utf8');
  raw = raw.replace(/\$\{(\w+)\}/g, (_, k) => process.env[k] || '');
  return yaml.parse(raw);
}

// 模块加载时缓存一次
const config = loadConfig();
module.exports = { loadConfig, config };
