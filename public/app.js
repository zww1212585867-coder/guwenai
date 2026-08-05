// 认知导航器前端：三态状态机驱动（diagnose / plan / execute / finish）
const API = '';
const $ = (s) => document.querySelector(s);
const log = $('#log');

const state = {
  visitorId: localStorage.getItem('cn_visitor') || (crypto.randomUUID()),
  conversationId: null,
  mode: 'diagnose',
  pendingQuestions: [],     // 当前 diagnose 轮的问题（供选项 UI）
  answers: {},              // qkey -> { answer, skipped, assumption }
  finishSummary: null,
};
localStorage.setItem('cn_visitor', state.visitorId);

function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
}
function scrollDown() { $('.stage').scrollTop = $('.stage').scrollHeight; }

function addMsg(role, node) {
  const m = el('div', 'msg ' + role);
  const b = el('div', 'bubble');
  b.appendChild(node);
  m.appendChild(b);
  log.appendChild(m);
  scrollDown();
}

// ---------- API ----------
async function nav(body) {
  let r;
  try {
    r = await fetch(API + '/api/navigation', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
  } catch (e) {
    throw new Error('无法连接服务器（' + (e.message || e) + '）— 请检查 VPS 上 node 服务是否在跑');
  }
  const ct = r.headers.get('content-type') || '';
  const raw = await r.text();
  if (!r.ok) {
    // nginx 通常会回 HTML 404/502，把状态码 + 前 80 字符贴出来
    throw new Error(`服务器返回 ${r.status}：${raw.slice(0, 120)}`);
  }
  if (!ct.includes('json')) {
    throw new Error(`服务器返回的不是 JSON（可能是 nginx 404 页面）。前 80 字符：${raw.slice(0, 120)}`);
  }
  try { return JSON.parse(raw); } catch (e) {
    throw new Error('JSON 解析失败：' + (e.message || e) + ' · 原文：' + raw.slice(0, 120));
  }
}

// ---------- 渲染：诊断态 ----------
function renderDiagnose(out) {
  const wrap = el('div');
  const cls = out.classification || {};
  wrap.appendChild(el('div', 'classification',
    `领域 <b>${cls.domain || '-'}</b> · 任务 <b>${cls.task_type || '-'}</b> · ${cls.intent || ''}`));

  const suf = (out.sufficiency && out.sufficiency.score) ?? 0;
  const bar = el('div', 'suff', `<i style="width:${suf}%"></i>`);
  wrap.appendChild(bar);
  wrap.appendChild(el('div', 'classification', `信息充足度 ${suf}/100 — ${out.sufficiency?.reason || ''}`));

  state.pendingQuestions = out.questions || [];
  state.answers = {};
  for (const q of state.pendingQuestions) {
    const card = el('div', 'qcard');
    const head = el('div');
    head.innerHTML = `<span class="badge ${q.criticality}">${q.criticality}</span> <b>${q.question}</b>`;
    card.appendChild(head);
    if (q.why) card.appendChild(el('div', 'why', q.why));

    if (q.options && q.options.length) {
      const opts = el('div', 'options');
      for (const o of q.options) {
        const b = el('span', 'opt', o);
        b.onclick = () => {
          opts.querySelectorAll('.opt').forEach(x => x.classList.remove('sel'));
          b.classList.add('sel');
          state.answers[q.key] = { answer: o, skipped: false };
        };
        opts.appendChild(b);
      }
      card.appendChild(opts);
    }
    if (q.criticality === 'assumable') {
      const skip = el('span', 'skip', `跳过（默认：${q.default_assumption || '由顾问假设'}）`);
      skip.onclick = () => {
        state.answers[q.key] = { skipped: true, assumption: q.default_assumption || null };
        card.style.opacity = .5;
      };
      card.appendChild(skip);
    }
    wrap.appendChild(card);
  }

  addMsg('ai', wrap);
  // 诊断态：显示"生成路线图"按钮
  showPlanActions({ plan: true, execute: false, finish: false });
  if (out.ready_to_plan) $('#btnPlan').classList.remove('hidden');
}

// ---------- 渲染：规划态 ----------
function renderPlan(out) {
  const wrap = el('div');
  if (out.assumptions && out.assumptions.length) {
    const a = out.assumptions.map(x => `· ${x.question} → ${x.assumed}`).join('<br>');
    wrap.appendChild(el('div', 'classification', '<b>基于以下假设：</b><br>' + a));
  }
  const ul = el('ul', 'roadmap');
  for (const s of out.roadmap || []) {
    const li = el('li');
    const ownerCls = s.owner === 'expert' ? 'owner expert' : 'owner';
    li.innerHTML = `<span class="step-no">第 ${s.step} 步</span><span class="${ownerCls}">${s.owner === 'expert' ? '转专家' : '你自己'}</span><br>
      <b>${s.what}</b><div class="meta">为什么：${s.why} · 预计 ${s.eta} · 完成标准：${s.done_when} · 下一步：${s.next}</div>`;
    if (s.owner === 'expert' && s.expert_handoff) {
      const cp = el('div', 'copy-handoff', '📋 复制给专家 AI 的 Prompt');
      cp.onclick = () => {
        navigator.clipboard.writeText(s.expert_handoff.prompt);
        cp.textContent = '✓ 已复制';
      };
      li.appendChild(cp);
    }
    ul.appendChild(li);
  }
  wrap.appendChild(ul);
  addMsg('ai', wrap);
  showPlanActions({ plan: false, execute: true, finish: true });
}

// ---------- 渲染：陪跑态 ----------
function renderExecute(out) {
  const wrap = el('div');
  wrap.appendChild(el('div', 'classification', `卡在第 ${out.step_ref} 步 · 类型：${out.blocker_type}`));
  wrap.appendChild(el('div', '', out.help || ''));
  if (out.expert_handoff) {
    const cp = el('div', 'copy-handoff', '📋 复制给专家 AI 的 Prompt');
    cp.onclick = () => { navigator.clipboard.writeText(out.expert_handoff.prompt); cp.textContent = '✓ 已复制'; };
    wrap.appendChild(cp);
  }
  if (out.confirm_question) wrap.appendChild(el('div', 'classification', out.confirm_question));
  addMsg('ai', wrap);
  showPlanActions({ plan: false, execute: false, finish: true });
}

// ---------- 渲染：完成态 ----------
function renderFinish(res) {
  const wrap = el('div');
  wrap.appendChild(el('div', '', `<b>总结：</b>${res.summary?.summary || ''}`));
  wrap.appendChild(el('div', 'classification', `下一步建议：${res.summary?.next_suggestion || ''}`));
  if (res.profile) wrap.appendChild(el('div', 'classification',
    `你的画像：水平 ${res.profile.level || '-'} · 目标 ${res.profile.goal || '-'} · 下一步节点 ${res.profile.next_node || '-'}`));
  addMsg('ai', wrap);
  $('#feedbackBox').classList.remove('hidden');
}

function showPlanActions({ plan, execute, finish }) {
  $('#planActions').classList.remove('hidden');
  $('#btnPlan').classList.toggle('hidden', !plan);
  $('#btnExecute').classList.toggle('hidden', !execute);
  $('#btnFinish').classList.toggle('hidden', !finish);
}

// ---------- 交互 ----------
async function send() {
  const text = $('#input').value.trim();
  if (!text && Object.keys(state.answers).length === 0) return;
  addMsg('user', el('div', '', text || '（已回答/跳过问题）'));
  $('#input').value = '';

  const answersArr = Object.entries(state.answers).map(([qkey, v]) => ({ qkey, ...v }));
  const body = { visitor_id: state.visitorId, conversation_id: state.conversationId, message: text, answers: answersArr };
  try {
    const res = await nav(body);
    state.conversationId = res.conversation_id;
    state.mode = res.mode;
    if (res.mode === 'diagnose') renderDiagnose(res.output);
    else if (res.mode === 'plan') renderPlan(res.output);
    else if (res.mode === 'execute') renderExecute(res.output);
  } catch (e) {
    const err = el('div', 'err', '⚠️ ' + (e.message || e));
    addMsg('ai', err);
    console.error('[navigation]', e);
  }
}

async function doPlan() {
  const res = await nav({ visitor_id: state.visitorId, conversation_id: state.conversationId, action: 'plan' });
  state.mode = 'plan';
  renderPlan(res.output);
}
async function doFinish() {
  const res = await nav({ visitor_id: state.visitorId, conversation_id: state.conversationId, action: 'finish' });
  state.mode = 'finish';
  renderFinish(res);
  $('#planActions').classList.add('hidden');
}
function doExecute() {
  state.mode = 'execute';
  showPlanActions({ plan: false, execute: false, finish: true });
  $('#input').focus();
  addMsg('ai', el('div', 'classification', '已进入陪跑模式，告诉我你卡在哪一步。'));
}

async function sendFeedback(score) {
  await fetch(API + '/api/feedback', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ visitor_id: state.visitorId, conversation_id: state.conversationId, score }),
  });
  document.querySelectorAll('#stars span').forEach(s => {
    s.classList.toggle('on', Number(s.dataset.score) <= score);
  });
}

// ---------- 启动 ----------
async function init() {
  await fetch(API + '/api/visitor', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ visitor_id: state.visitorId, consent_version: 'v1' }) }).catch(() => {});
  try {
    const d = await (await fetch(API + '/api/domains')).json();
    if (Array.isArray(d)) $('#domainChips').innerHTML = d.map(x => `<span class="chip">${x.label}</span>`).join('');
  } catch (e) { /* 字典暂时不可用不阻塞 */ }

  $('#btnSend').onclick = send;
  $('#input').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
  $('#btnPlan').onclick = doPlan;
  $('#btnExecute').onclick = doExecute;
  $('#btnFinish').onclick = doFinish;
  document.querySelectorAll('#stars span').forEach(s => { s.onclick = () => sendFeedback(Number(s.dataset.score)); });

  // Hero 示例点击 → 自动填进输入框 → 触发发送
  document.querySelectorAll('.hero .example').forEach(b => {
    b.onclick = () => {
      $('#input').value = b.textContent.trim();
      $('#input').focus();
      send();
    };
  });

  addMsg('ai', el('div', '', '你好，我是你的认知导航员。说说你想完成的事——我不会急着给方案，先把关键问题问清楚。'));
}
init();
