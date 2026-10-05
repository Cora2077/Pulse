#!/bin/sh
# Run a bounded worker through the user's existing DSH sign-in.
set -eu

dsh_bin=${PULSE_DSH_BIN:-/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh}
workbuddy_plugin=${PULSE_WORKBUDDY_PLUGIN:-${DSH_HOME:-$HOME/.dsh}/profiles/desktop/node_modules/dsh-connect-workbuddy/lib/index.js}
if [ ! -x "$dsh_bin" ]; then
    echo 'DSH is missing.' >&2
    exit 1
fi

worker_patch=$(mktemp -t pulse-dsh-worker)
trap 'rm -f "$worker_patch"' EXIT HUP INT TERM
case "${PULSE_DSH_WORKER:-flash}" in
  flash)
    if [ ! -f "$workbuddy_plugin" ]; then
        echo 'The installed WorkBuddy connector is missing.' >&2
        exit 1
    fi
    worker_mode=${DSH_PERMISSION_MODE:-workspace-write}
cat > "$worker_patch" <<EOF
- id: agent-default-model
  config:
    provider: workbuddy
    model: deepseek-v4.1-flash
- insert:
    - id: dsh-connect-workbuddy
      name: "$workbuddy_plugin"
      config:
        regions:
          cn:
            enabled: true
            enabledModelIds: [deepseek-v4.1-flash]
            lastCatalog:
              - id: deepseek-v4.1-flash
                name: DeepSeek V4.1 Flash
                contextWindow: 64000
                maxTokens: 16000
          global:
            enabled: false
EOF
    ;;
  kimi)
    worker_mode=${DSH_PERMISSION_MODE:-read-only}
cat > "$worker_patch" <<'EOF'
- id: agent-default-model
  config:
    provider: kimi-coding
    model: k3
- id: llm-pi-ai
  config:
    providers:
      kimi-coding:
        apiKeyEnv: KIMI_CODING_API_KEY
EOF
    ;;
  *)
    echo 'Unsupported worker; choose flash or kimi.' >&2
    exit 2
    ;;
esac
case "$worker_mode" in
  read-only|workspace-write) ;;
  *) echo 'Unsupported access mode.' >&2; exit 2 ;;
esac
cat >> "$worker_patch" <<EOF
- id: session-title-llm
  disabled: true
- id: approval
  config:
    policy: never
- id: permission
  config:
    defaultPreset: $worker_mode
EOF
if [ "$worker_mode" = read-only ]; then
cat >> "$worker_patch" <<'EOF'
    presets:
      read-only:
        sandbox: read-only
        approval: never
        name: Read only
        description: Review project files without writing them.
EOF
fi
# The live WorkBuddy catalog replaces the conservative startup limits above.
# Use the model's supported default reasoning instead of imposing Luna's scale.
DSH_PERMISSION_MODE="$worker_mode" "$dsh_bin" headless --patch "$worker_patch" "$@" -
