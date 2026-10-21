#!/bin/sh
# Run a bounded worker through the user's existing DSH sign-in.
set -eu

dsh_bin=${PULSE_DSH_BIN:-/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh}
# The connector lives in whichever DSH home actually holds it. A workspace-local
# DSH_HOME (used when a sandbox forbids writing the real one) carries a symlink
# instead of the package, so fall back to the real home when the link is absent.
if [ -n "${PULSE_WORKBUDDY_PLUGIN:-}" ]; then
    workbuddy_plugin=$PULSE_WORKBUDDY_PLUGIN
elif [ -f "${DSH_HOME:-$HOME/.dsh}/profiles/desktop/node_modules/dsh-connect-workbuddy/lib/index.js" ]; then
    workbuddy_plugin=${DSH_HOME:-$HOME/.dsh}/profiles/desktop/node_modules/dsh-connect-workbuddy/lib/index.js
else
    workbuddy_plugin=$HOME/.dsh/profiles/desktop/node_modules/dsh-connect-workbuddy/lib/index.js
fi
if [ ! -x "$dsh_bin" ]; then
    echo 'DSH is missing.' >&2
    exit 1
fi

worker_patch=$(mktemp -t pulse-dsh-worker)
trap 'rm -f "$worker_patch"' EXIT HUP INT TERM
case "${PULSE_DSH_WORKER:-flash}" in
  step|flash)
    case "${PULSE_DSH_WORKER:-flash}" in
      flash)
        worker_model=deepseek-v4.1-flash
        worker_model_name=Deepseek-V4.1-Flash
        ;;
      step)
        worker_model=step-5-preview
        worker_model_name=Step-5-Preview
        ;;
    esac
    worker_context=500000
    worker_max_tokens=64000
    if [ ! -f "$workbuddy_plugin" ]; then
        echo 'The installed WorkBuddy connector is missing.' >&2
        exit 1
    fi
    worker_mode=${DSH_PERMISSION_MODE:-workspace-write}
    # Pin only the worker's plugin configuration, never the GUI's account pool.
    account_slot=""
    pool_slot=""
    if [ -n "${PULSE_WORKBUDDY_ACCOUNT_ID:-}" ]; then
      case "$PULSE_WORKBUDDY_ACCOUNT_ID" in
        *[!a-fA-F0-9]*) echo 'Invalid WorkBuddy account id.' >&2; exit 2 ;;
      esac
      if [ "${#PULSE_WORKBUDDY_ACCOUNT_ID}" -ne 24 ]; then
        echo 'Invalid WorkBuddy account id length.' >&2
        exit 2
      fi
      account_slot="        accounts:
          cn: \"$PULSE_WORKBUDDY_ACCOUNT_ID\""
      pool_slot="            pool:
              enabled: false"
    fi
cat > "$worker_patch" <<EOF
- id: agent-default-model
  config:
    provider: workbuddy
    model: $worker_model
- insert:
    - id: dsh-connect-workbuddy
      name: "$workbuddy_plugin"
      config:
$account_slot
        regions:
          cn:
            enabled: true
$pool_slot
            enabledModelIds: [$worker_model]
            lastCatalog:
              - id: $worker_model
                name: $worker_model_name
                contextWindow: $worker_context
                maxTokens: $worker_max_tokens
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
    echo 'Unsupported worker; choose flash, step, or kimi.' >&2
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
# The live WorkBuddy catalog replaces the startup limits above. The human
# restored DeepSeek 4.1 Flash for routine workers on 2026-10-20.
# Keep the selected model's default reasoning effort.
DSH_PERMISSION_MODE="$worker_mode" "$dsh_bin" headless --patch "$worker_patch" "$@" -
