#!/usr/bin/env bash
# smoke-bash-syntax.sh — sanity-check core scripts under macOS bash 3.2.
#
# macOS ships /bin/bash 3.2.57 from 2007. Several bash 4+ idioms (e.g.
# ${var^^}, mapfile, declare -A) silently parse on Linux's bash 5+ but
# crash with "bad substitution" on the production agents. This smoke test
# is the cheapest possible guard: it just runs `/bin/bash -n` against the
# core scripts and greps for known-broken idioms. Wire it into a pre-push
# hook or run it manually after editing fast-checker.sh / register-* /
# agent-wrapper.sh.
#
# Exit codes:
#   0 — clean
#   1 — syntax error or bash 4+ idiom found
#
# Usage:
#   tests/smoke-bash-syntax.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS=(
    "${REPO_ROOT}/core/scripts/fast-checker.sh"
    "${REPO_ROOT}/core/scripts/register-telegram-commands.sh"
    "${REPO_ROOT}/core/scripts/agent-wrapper.sh"
    "${REPO_ROOT}/core/scripts/health-check.sh"
)

FAIL=0

for script in "${SCRIPTS[@]}"; do
    [[ -f "${script}" ]] || { echo "MISSING: ${script}"; FAIL=1; continue; }

    # 1. Parse under /bin/bash (which is bash 3.2 on macOS).
    if /bin/bash -n "${script}" 2>/dev/null; then
        echo "OK   bash3 parse: $(basename "${script}")"
    else
        echo "FAIL bash3 parse: ${script}" >&2
        /bin/bash -n "${script}" || true
        FAIL=1
    fi

    # 2. Grep for bash 4+ idioms that parse cleanly but crash at runtime.
    # Each alternation matches a known bash 4+ feature that bash 3.2 either
    # tokenises silently (parameter expansions) or accepts under `bash -n`
    # but rejects when actually executed (`mapfile`, `readarray`, the `-A`,
    # `-g` and `-n` declare flags in any combination order, namerefs).
    # The `-[a-zA-Z]*[Agn][a-zA-Z]*` slice catches `-A`, `-g`, `-n`, plus
    # combined forms like `-gA`, `-Ag`, `-gn`, `-Agn`, etc. — without
    # false-positiving on bash 3.2-valid flags like `-a`, `-f`, `-i`, `-r`.
    BAD_PATTERNS=$(grep -nE \
        '\$\{[A-Za-z_0-9]+\^\^?\}|\$\{[A-Za-z_0-9]+,,?\}|^[[:space:]]*mapfile\b|^[[:space:]]*readarray\b|^[[:space:]]*declare[[:space:]]+-[a-zA-Z]*[Agn][a-zA-Z]*\b|^[[:space:]]*local[[:space:]]+-n\b|^[[:space:]]*typeset[[:space:]]+-n\b' \
        "${script}" || true)
    if [[ -n "${BAD_PATTERNS}" ]]; then
        echo "FAIL bash4 idiom: ${script}" >&2
        echo "${BAD_PATTERNS}" >&2
        FAIL=1
    else
        echo "OK   bash4 grep:  $(basename "${script}")"
    fi
done

if (( FAIL )); then
    echo ""
    echo "Smoke test FAILED — fix bash 3.2 incompatibilities before pushing."
    exit 1
fi

echo ""
echo "Smoke test PASSED — core scripts compatible with macOS bash 3.2."
