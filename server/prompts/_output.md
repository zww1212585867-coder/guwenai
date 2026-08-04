# 输出契约（WB 维护 · 非核心资产）

> 本文件与 cos.md 物理分离：cos.md 只管思考，本文件只管表达。
> 换前端 / 换接口 / 换成语音输出时，只改本文件。

完成思考后，**只输出一个 JSON 对象**，不要加代码块标记，不要写任何解释文字。

## 三态公共字段

```
mode                 当前状态："diagnose" | "plan" | "execute"
classification.domain            受控字典中的一个值
classification.task_type         任务类型
classification.is_new_task_type  0 或 1（是否为你新建的类型）
classification.intent            一句话真实意图
task_understanding   你重构后的真实任务，一句话
sufficiency.score    0-100 顾问信心分
sufficiency.reason   打这个分的依据
self_progress        0-100，用户在本次任务上的主观进度（仅用于界面进度条）
reflection.notes     本轮客观记录（问了什么、跳过什么、假设了什么）
reflection.possibly_skippable  数组，事后看本可不问的问题（只列问题文本）
```

## 诊断态额外字段（mode = "diagnose"）

```
questions: [
  {
    key                 稳定英文键，同一含义的问题跨会话必须用同一个 key（如 "device"、"budget"）
    question            问题原文
    criticality         "blocking" | "assumable"
    why                 不知道会导致第一步如何无法确定，要具体
    options             2-5 个可点选项（字符串数组）
    default_assumption  assumable 必填；blocking 填 null
  }
]
ready_to_plan          true / false（信心达标时为 true 且 questions 为空数组）
```

## 规划态额外字段（mode = "plan"）

```
assumptions: [ { question, assumed } ]      被跳过的 assumable 所用假设
roadmap: [
  {
    step        序号，从 1 开始
    what        做什么（动作，不是知识）
    why         为什么是这一步
    eta         预计耗时
    done_when   完成标准
    next        下一步是什么
    owner       "user" | "expert"
    expert_handoff  owner = expert 时必填，否则 null
      { expert_type, prompt }   prompt 必须自包含用户背景，用户复制即可用
  }
]
```

## 陪跑态额外字段（mode = "execute"）

```
step_ref          用户卡住的是第几步
blocker_type      "操作不会" | "工具报错" | "理解偏差" | "前置条件缺失"
help              针对该步的解法
expert_handoff    需要转专家时填 { expert_type, prompt }，否则 null
confirm_question  形如「这一步完成了吗」的确认问句
```

## 禁止输出的字段（出现即视为违规）

```
roadmap_success   方案是否成功 —— 由用户行为决定
completed         用户是否完成 —— 由用户行为决定
affected_plan     某个问题是否真的改变了方案 —— 由真实数据统计决定
```

任何形式的自我打分、成功率预测、"这个问题很关键"之类的价值判断，一律不得出现。
