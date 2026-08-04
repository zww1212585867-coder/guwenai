// 模型调用层：DeepSeek / Qwen / OpenAI 兼容接口
// 无 API Key 时返回按状态区分的离线 stub，保证整链可本地演示
function buildMessages(systemPrompt, history, userMessage) {
  const msgs = [{ role: 'system', content: systemPrompt }];
  for (const m of history || []) msgs.push({ role: m.role, content: m.content });
  if (userMessage) msgs.push({ role: 'user', content: userMessage });
  return msgs;
}

async function chat(cfg, messages, opts = {}) {
  const key = cfg.model && cfg.model.apiKey;
  if (!key) return stubResponse(messages, opts.mode || 'diagnose');

  const body = {
    model: cfg.model.model,
    messages,
    temperature: cfg.model.temperature ?? 0.7,
    max_tokens: opts.maxTokens ?? cfg.model.maxTokens ?? 2000,
  };
  if (opts.json) body.response_format = { type: 'json_object' };

  const res = await fetch(`${cfg.model.baseUrl}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Model API ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const usage = data.usage || {};
  return {
    content: data.choices[0].message.content,
    tokenCost: (usage.prompt_tokens || 0) + (usage.completion_tokens || 0),
  };
}

// ---------- 离线 stub ----------
function lastUser(messages) {
  for (let i = messages.length - 1; i >= 0; i--) if (messages[i].role === 'user') return messages[i].content;
  return '';
}

function stubResponse(messages, mode) {
  const q = lastUser(messages);

  if (mode === 'memory') {
    return {
      content: JSON.stringify({
        domain: 'other',
        level: '入门',
        goal: '（离线占位）' + q.slice(0, 40),
        motivation: '（离线模式不提取真实动机）',
        resources: '',
        current_position: '未知',
        known_nodes: [],
        unknown_nodes: [],
        next_node: '（离线占位）先完成第一步',
        risk: '（离线模式不评估风险）',
      }),
      tokenCost: 0,
    };
  }
  if (mode === 'summary') {
    return {
      content: JSON.stringify({
        summary: '（离线演示）本次导航未接入模型，已生成结构占位总结。配置 API Key 后将输出真实总结。',
        next_suggestion: '（离线占位）按路线图第一步执行，遇到卡点回来说。',
      }),
      tokenCost: 0,
    };
  }

  const base = {
    mode,
    classification: { domain: 'other', task_type: '未分类任务', is_new_task_type: 1, intent: '（离线模式）' + q.slice(0, 40) },
    task_understanding: '（离线演示）未配置模型 API Key，以下为结构占位。真实任务重构需接入模型。',
    sufficiency: { score: mode === 'diagnose' ? 45 : 80, reason: '离线模式固定分值' },
    self_progress: mode === 'plan' ? 40 : 15,
    reflection: { notes: '离线模式不产生真实经验记录', possibly_skippable: [] },
  };

  if (mode === 'plan') {
    Object.assign(base, {
      assumptions: [{ question: '预算', assumed: '按免费方案规划' }],
      roadmap: [
        { step: 1, what: '确认你手上已有的工具', why: '决定第一步装什么', eta: '5 分钟', done_when: '列出已装软件', next: '选定主工具', owner: 'user', expert_handoff: null },
        { step: 2, what: '安装并跑通主工具的最小示例', why: '先跑通再谈效果', eta: '30 分钟', done_when: '导出一个成品文件', next: '替换成自己的素材', owner: 'user', expert_handoff: null },
        { step: 3, what: '处理专业参数调优', why: '超出通用范围', eta: '视情况', done_when: '参数达标', next: '产出终稿', owner: 'expert', expert_handoff: { expert_type: '该领域专家 AI', prompt: '（离线占位）我的目标是…，我会…，我的限制是…，请帮我完成第 3 步。' } },
      ],
    });
  } else if (mode === 'execute') {
    Object.assign(base, {
      step_ref: 2, blocker_type: '操作不会',
      help: '（离线演示）针对你卡住的这一步，真实模式下这里会给出定点解法，不会重讲整条路线。',
      expert_handoff: null, confirm_question: '这一步完成了吗？',
    });
  } else {
    Object.assign(base, {
      ready_to_plan: false,
      questions: [
        { key: 'device', question: '你打算用手机还是电脑来做？', criticality: 'blocking', why: '设备不同，第一步要装的软件完全不同', options: ['手机', '电脑', '两个都有'], default_assumption: null },
        { key: 'goal_use', question: '做出来主要用来干什么？', criticality: 'blocking', why: '自用和商用会走两条不同路线', options: ['发社交媒体', '自己玩', '接单赚钱'], default_assumption: null },
        { key: 'budget', question: '愿意付费吗？', criticality: 'assumable', why: '影响工具选型，但不影响第一步', options: ['只要免费', '100 元内', '不限'], default_assumption: '按免费工具规划' },
      ],
    });
  }
  return { content: JSON.stringify(base), tokenCost: 0 };
}

module.exports = { chat, buildMessages };
