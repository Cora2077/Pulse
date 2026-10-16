# Development model assignments

- Primary agent and final reviewer: **GPT-6.1 Sol**, reasoning **High**. Own requirements, architecture, task breakdown, acceptance criteria, synthesis, and final diff/test review.
- Implementation and testing workers: per the user's 2026-10-16 instruction, use the locally installed DSH **WorkBuddy** provider with **`step-5-preview` (Step-5-Preview)** via `scripts/dsh-worker.sh` (default selector `step`). Its plugin catalog reported credit multiplier 0 when selected; recheck promotional availability if pricing changes. Do not start new DeepSeek 4.1 workers. Use the model's supported default reasoning and send a self-contained, bounded task through stdin.
- Kimi K3 was explicitly reauthorized by the user on 2026-10-16 for difficult implementation and independent review. Use it selectively with disjoint write scopes; ordinary work stays on Step 5. The primary agent retains architecture, financial-data safety and final judgment.
- Frontend delivery order: the primary agent supplies concrete visual/interaction specifications, Step 5 implements bounded tasks, then the primary agent performs final code, test, and actual native/simulator render review. Source review alone does not validate visual quality.
- Give each worker explicit file ownership and acceptance checks. Do not send chat history, secrets, credentials, or real account data. Workers must not sign/install apps, commit/push, contact people, or perform account actions. The primary agent reviews their diff and verification results.
- Do not pass third-party model IDs to native collaboration tools. If the DSH worker fails, report the actual failure and continue necessary work in the primary agent; do not silently substitute Luna.
- The primary model is configured in the chat settings; do not claim to have changed it through delegation.

# Local macOS signing

- Use `scripts/dev-mac.sh` for local builds, or reuse its discovered identity and team when invoking Xcode directly. The installed daily app uses the persistent `Fight For Free Local Development` identity in the login Keychain; keep reusing it rather than creating a new certificate or switching signers. Its default requirement pins the certificate without adding a trusted root. Do not force ad-hoc signing (`CODE_SIGN_IDENTITY=-`): it causes Keychain approvals to repeat after every rebuild. Keep certificate identifiers and private keys out of the repository.
- Daily installations require a stable certificate. If none is available, complete compile-only checks and ask the user to set up a signing identity; do not install an ad-hoc replacement. `PULSE_ALLOW_AD_HOC=1 scripts/dev-mac.sh --build` is reserved for isolated compilation checks and must not be used to update the daily app.
- By default, update the user's installed daily app at `/Users/cora/Applications/FFF.app` after focused checks, then verify that installed app. Avoid switching between demo and daily versions; use an isolated demo only when explicitly requested or necessary to keep a test from changing real data.

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
