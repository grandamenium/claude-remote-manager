#!/usr/bin/env bash
# register-telegram-commands.sh - Register skills/commands as Telegram bot / autocomplete
#
# Scans directories for Claude Code skills and commands, parses their YAML
# frontmatter, and registers user-invocable ones via Telegram's setMyCommands API.
#
# Usage: register-telegram-commands.sh <bot_token> <scan_dir> [<scan_dir2> ...]
#
# Scanned locations (per directory):
#   .claude/commands/*.md     - Claude Code slash commands
#   .claude/skills/*/SKILL.md - Claude Code skills
#   skills/*/SKILL.md         - Legacy/custom skills
#
# Frontmatter fields used:
#   name              - becomes the /command name (required or derived from filename)
#   description       - shown in Telegram autocomplete (max 256 chars)
#   user-invocable    - when "false", skill is excluded from registration

set -euo pipefail

BOT_TOKEN="$1"
shift
SCAN_DIRS=("$@")

if [[ -z "${BOT_TOKEN}" ]]; then
    echo "ERROR: BOT_TOKEN required" >&2
    exit 1
fi

# --- Frontmatter parser ---
# Reads YAML frontmatter from a markdown file. Handles single-line values,
# quoted strings, and YAML multi-line indicators (>-, >, |-, |).
# Output: name|description|user-invocable (pipe-delimited)
parse_frontmatter() {
    local file="$1"
    local in_frontmatter=false
    local name="" description="" user_invocable="true"
    local reading_multiline="" multiline_value=""

    while IFS= read -r line; do
        # Detect frontmatter boundaries
        if [[ "${line}" == "---" ]]; then
            if [[ "${in_frontmatter}" == "true" ]]; then
                break
            fi
            in_frontmatter=true
            continue
        fi
        [[ "${in_frontmatter}" == "true" ]] || continue

        # Multi-line continuation: indented lines belong to the previous field
        if [[ -n "${reading_multiline}" && "${line}" =~ ^[[:space:]] ]]; then
            local trimmed
            trimmed=$(echo "${line}" | sed 's/^[[:space:]]*//')
            multiline_value="${multiline_value} ${trimmed}"
            continue
        elif [[ -n "${reading_multiline}" ]]; then
            # Assign without eval to avoid injection risk from untrusted frontmatter
            case "${reading_multiline}" in
                description) description="${multiline_value}" ;;
                name) name="${multiline_value}" ;;
            esac
            reading_multiline=""
            multiline_value=""
        fi

        # Parse known fields
        case "${line}" in
            name:*)
                name=$(echo "${line#name:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
                ;;
            description:*)
                local val
                val=$(echo "${line#description:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
                if [[ "${val}" =~ ^[\>\|]-?$ ]]; then
                    reading_multiline="description"
                    multiline_value=""
                else
                    description="${val}"
                fi
                ;;
            user-invocable:*)
                user_invocable=$(echo "${line#user-invocable:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
        esac
    done < "$file"

    # Flush remaining multi-line value
    if [[ -n "${reading_multiline}" ]]; then
        case "${reading_multiline}" in
            description) description="${multiline_value}" ;;
            name) name="${multiline_value}" ;;
        esac
    fi

    description=$(echo "${description}" | sed 's/^[[:space:]]*//')
    echo "${name}|${description}|${user_invocable}"
}

# --- Collect skill files from all scan directories ---
collect_skill_files() {
    local dir="$1"
    local paths=(
        "${dir}/.claude/commands/*.md"
        "${dir}/.claude/skills/*/SKILL.md"
        "${dir}/skills/*/SKILL.md"
    )
    for pattern in "${paths[@]}"; do
        for file in ${pattern}; do
            [[ -f "${file}" ]] && echo "${file}"
        done
    done
}

# --- Derive command name from file path ---
# SKILL.md -> use parent directory name; *.md -> use filename without extension
derive_name() {
    local file="$1"
    if [[ "$(basename "${file}")" == "SKILL.md" ]]; then
        basename "$(dirname "${file}")"
    else
        basename "${file}" .md
    fi
}

# --- Sanitize name for Telegram ---
# Telegram commands: lowercase, a-z 0-9 underscore only, max 32 chars
sanitize_command() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr '-' '_' | sed 's/[^a-z0-9_]//g' | cut -c1-32
}

# --- Build commands JSON array ---
COMMANDS_JSON="[]"
SEEN=""

for dir in "${SCAN_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue

    while IFS= read -r file; do
        IFS='|' read -r name desc invocable <<< "$(parse_frontmatter "${file}")"

        [[ -z "${name}" ]] && name=$(derive_name "${file}")
        [[ -z "${desc}" ]] && desc="Skill: ${name}"
        [[ "${invocable}" == "false" ]] && continue

        cmd=$(sanitize_command "${name}")
        [[ -z "${cmd}" ]] && continue

        # Deduplicate (first occurrence wins)
        echo "${SEEN}" | grep -q "^${cmd}$" && continue
        SEEN="${SEEN}${cmd}"$'\n'

        # jq handles all JSON escaping; truncate description to Telegram's limit
        COMMANDS_JSON=$(echo "${COMMANDS_JSON}" | jq \
            --arg cmd "${cmd}" \
            --arg desc "$(echo "${desc}" | cut -c1-256)" \
            '. + [{"command": $cmd, "description": $desc}]')
    done <<< "$(collect_skill_files "${dir}")"
done

# --- Register with Telegram ---
COUNT=$(echo "${COMMANDS_JSON}" | jq 'length')

if [[ "${COUNT}" -eq 0 ]]; then
    echo "No commands found to register"
    exit 0
fi

PAYLOAD=$(jq -n --argjson cmds "${COMMANDS_JSON}" '{"commands": $cmds}')
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")

if echo "${RESPONSE}" | jq -e '.ok == true' > /dev/null 2>&1; then
    echo "Registered ${COUNT} Telegram commands"
else
    echo "WARNING: Failed to register Telegram commands: ${RESPONSE}" >&2
fi
