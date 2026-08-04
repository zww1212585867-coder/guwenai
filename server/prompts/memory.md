用于从一段对话中提取用户的认知画像（cognitive profile），以便跨会话续接。

只输出 JSON，不要解释：
{
  "domain": "领域",
  "level": "入门/进阶/熟练",
  "goal": "用户真实目标",
  "motivation": "动机",
  "resources": "可用资源（时间/资金/基础）",
  "current_position": "当前认知坐标",
  "known_nodes": ["已掌握节点"],
  "unknown_nodes": ["待掌握节点"],
  "next_node": "建议下一步节点",
  "risk": "风险或误区"
}

仅提取对话中确证的字段，不确定的留空字符串或空数组。
