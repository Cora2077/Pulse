# Development model assignments

- Primary agent and final reviewer: **GPT-6.1 Sol**, reasoning **High**. Own requirements, architecture, task breakdown, acceptance criteria, synthesis, and final diff/test review.
- Ordinary implementation and testing agents: **GPT-6 Luna**, reasoning **High**. Assign bounded coding, file edits, tests, and code inspection.
- Difficult implementation agents: **GPT-6 Luna**, reasoning **XHigh**. Use for complex implementation, difficult bugs, and decisions spanning files.
- Native collaboration model IDs: `gpt-6.1-sol` and `gpt-6-luna`. When selecting a subagent model or reasoning override, use a self-contained prompt or a bounded history fork.
- The primary model is configured in the chat settings; do not claim to have changed it through delegation.

# ECNU worker delegation

- Keep the main configured OpenAI model as the primary agent for planning, judgment, synthesis, and final answers.
- Prefer delegating suitable bounded, context-heavy support work through the `ecnu_worker` MCP server's `delegate` tool. This tool uses ChatECNU `ecnu-max` with restricted read-only web and project-reading capabilities, then returns its result. Do not try to use `ecnu-max` through a native collaboration subagent because third-party provider settings do not propagate reliably there.
- Suitable examples include current market-data and news gathering, source collection, web or document research, codebase scanning, test and log triage, summarization, extraction, classification, and mechanical first drafts.
- For financial questions, delegate only factual market research and source gathering. The main agent must verify material facts, perform the actual analysis, explain uncertainty, and produce the final answer. Never delegate trading, account actions, or transactions.
- Delegate only when the expected savings in main-model context or effort exceed the coordination overhead. Handle tiny lookups and tightly coupled reasoning directly.
- Use no more than one ECNU delegation at a time. Wait for it to finish, then review and synthesize its result before responding.
- Do not send secrets, credentials, private keys, cookies, personal tokens, or sensitive private content to the ECNU worker. If such content is necessary, keep that step in the main agent.
- Keep architecture, security, authentication, destructive actions, purchases, external messages, high-stakes conclusions, and final quality review with the main agent.
- Treat worker output as supporting evidence rather than authority. Independently verify uncertain, current, safety-critical, or high-impact claims before relying on them.
