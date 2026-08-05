# 输出契约（WB 维护 · 非核心资产）

> 本文件与 cos.md 物理分离：cos.md 只管思考，本文件只管表达。
> 换前端 / 换接口 / 换成语音输出时，只改本文件。

完成思考后，**只输出一个 JSON 对象**，不要加代码块标记，不要写任何解释文字。

## 三态公共字段

```
mode                 当前状态："diagnose" | "plan" | "execute"
classification.domain            受控字典中的一个值（导诊分类用，非领域树）
classification.task_type         任务类型
classification.is_new_task_type  0 或 1
classification.intent            一句话真实意图（B 的雏形）
task_understanding   你重构后的真实任务，一句话
sufficiency.score    0-100（保留兼容，等价于 confidence）
sufficiency.reason   打这个分的依据
self_progress        0-100，界面进度条用
reflection.notes     本轮客观记录
reflection.possibly_skippable  数组，事后看本可不问的问题
```

## 导诊收集态（mode = "diagnose"）

```
round                第几轮（1 或 2，封顶 2）
max_rounds           2
confidence           0-100，AI 自评：现在直接交给大模型能否产出优质分析
confidence_reason    为什么这个分（具体缺了什么）
questions: [                     # 本轮要问的（≤6），一次性列出，用户提交后整轮处理
  {
    key                 稳定英文键，跨轮同含义用同键
    question            问题原文
    criticality         "blocking" | "assumable"
    why                 为什么问——必须说明"不知道会导致分析哪部分失真"，要具体
    options             2-5 个可点选项（建议回复）
    default_assumption  assumable 必填；blocking 填 null
  }
]
# 当 confidence ≥ 70 或 round = 2 时，questions 为空，并输出下面两项：
problem_reconstruction: {        # 提炼的 B 问题（理解确认用）
  original        用户原始表达 A
  understood_as  你提炼的真正问题 B（一句话）
  gpt_needs      [ "已补:预算", "已补:经验", "仍缺:风险偏好" ]   # 大模型还需的关键信息
}
understanding_confirm: {          # 理解确认
  statement  "如果我理解没错，你真正想解决的是：<understood_as>？"
  options    ["✓ 对，就是这个", "✗ 不对，我解释一下"]
}
ready_to_plan   true / false（confidence≥70 或 round=2 时为 true 且 questions 为空）
```

## 分析态（mode = "plan"，替代旧"规划态/路线图"）

```
assumptions: [ { question, assumed } ]      被跳过的 assumable 所用假设
analysis_package: {                          # 给大模型的完整输入包（可复制）
  user_original        用户原始问题 A
  reconstructed        提炼后的真正问题 B
  context              { 已补全的键:值 }      # 导诊收集到的全部信息
  limitations          已知限制 / 采用的默认假设
  prompt_for_expert    自包含 Prompt：用户复制即可直接发给大模型
}
analysis: {                               # 大模型基于分析包产出的文字拆解
  steps    [ "第一步：...", "第二步：..." ]   # 文字拆解，非项目计划
  risks    [ "风险1...", "风险2..." ]
  gains    [ "可能收益1...", "可能收益2..." ]
}
```

## 陪跑态（mode = "execute"）

```
step_ref          用户卡住的是第几步
blocker_type      "操作不会" | "工具报错" | "理解偏差" | "前置条件缺失"
help              针对该步的解法
expert_handoff    需要转专家时填 { expert_type, prompt }，否则 null
confirm_question  形如「这一步完成了吗」的确认问句
```

## 禁止输出的字段（出现即违规）

```
roadmap_success   方案是否成功 —— 由用户行为决定
completed         用户是否完成 —— 由用户行为决定
affected_plan     某个问题是否真的改变了方案 —— 由真实数据统计决定
```

任何形式的自我打分、成功率预测、"这个问题很关键"之类的价值判断，一律不得出现。
