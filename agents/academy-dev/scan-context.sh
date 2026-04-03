#!/usr/bin/env bash
# scan-context.sh — Scans Clearpath codebase and generates ACADEMY-CONTEXT.md
# Run from any directory. Overwrites output each time.

set -euo pipefail

CLEARPATH_DIR="$HOME/code/clearpath"
OUTPUT_DIR="$HOME/code/claude-remote-manager/agents/academy-dev"
OUTPUT_FILE="$OUTPUT_DIR/ACADEMY-CONTEXT.md"

if [ ! -d "$CLEARPATH_DIR" ]; then
  echo "ERROR: Clearpath directory not found at $CLEARPATH_DIR" >&2
  exit 1
fi

# Start fresh
cat > "$OUTPUT_FILE" <<HEADER
# Academy Context — Auto-Generated

> Auto-generated on $(date). Do not edit manually.

HEADER

# ─────────────────────────────────────────────
# Section 1: Module Inventory
# ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" <<'SEC1'
## 1. Module Inventory

SEC1

MODULE_FILES="aware-modules.ts fluent-modules.ts strategic-modules.ts productivity-modules.ts tool-guide-modules.ts"

for file in $MODULE_FILES; do
  filepath="$CLEARPATH_DIR/shared/$file"
  if [ ! -f "$filepath" ]; then
    echo "  (skipping $file — not found)" >> "$OUTPUT_FILE"
    continue
  fi

  # Derive tier name from filename
  tier=$(echo "$file" | sed 's/-modules\.ts//')
  echo "### $tier" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
  echo "| Key | Title | Named Concept | Tier |" >> "$OUTPUT_FILE"
  echo "|-----|-------|---------------|------|" >> "$OUTPUT_FILE"

  # Extract fields using awk (field order: key, label, tier, sortOrder, namedConcept, conceptEquation)
  awk '
    /key:.*"/ && /aware_|fluent_|strategic_|prod_|tg_/ {
      s=$0; gsub(/.*key:[ ]*"/, "", s); gsub(/".*/, "", s); key=s
    }
    /label:.*"/ && key != "" && concept == "" {
      s=$0; gsub(/.*label:[ ]*"/, "", s); gsub(/".*/, "", s); label=s
    }
    /tier:.*"/ && key != "" && concept == "" {
      s=$0; gsub(/.*tier:[ ]*"/, "", s); gsub(/".*/, "", s); tier=s
    }
    /namedConcept:.*"/ && key != "" {
      s=$0; gsub(/.*namedConcept:[ ]*"/, "", s); gsub(/".*/, "", s); concept=s
      # Emit row now that we have all fields
      printf "| %s | %s | %s | %s |\n", key, label, concept, tier
      key=""; label=""; concept=""; tier=""
    }
  ' "$filepath" >> "$OUTPUT_FILE"

  echo "" >> "$OUTPUT_FILE"
done

# ─────────────────────────────────────────────
# Section 2: File Map
# ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" <<'SEC2'
## 2. File Map

SEC2

echo "### shared/ (content definitions)" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
find "$CLEARPATH_DIR/shared" -maxdepth 1 -name '*academy*' -o -name '*modules*' | \
  sed "s|$CLEARPATH_DIR/||" | sort >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "### server/ (routes, storage, seeds)" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
(
  find "$CLEARPATH_DIR/server/routes" -maxdepth 1 -name '*academy*' 2>/dev/null
  find "$CLEARPATH_DIR/server/storage" -maxdepth 1 -name '*academy*' 2>/dev/null
  find "$CLEARPATH_DIR/server" -maxdepth 1 -name '*academy*' -o -name '*seed-academy*' 2>/dev/null
) | sed "s|$CLEARPATH_DIR/||" | sort -u >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "### client/src/pages/ (academy pages)" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
find "$CLEARPATH_DIR/client/src/pages" -maxdepth 1 -name '*academy*' 2>/dev/null | \
  sed "s|$CLEARPATH_DIR/||" | sort >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "### client/src/components/academy/ (components)" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
find "$CLEARPATH_DIR/client/src/components/academy" -maxdepth 1 -type f 2>/dev/null | \
  sed "s|$CLEARPATH_DIR/||" | sort >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ─────────────────────────────────────────────
# Section 3: Database Tables
# ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" <<'SEC3'
## 3. Database Tables

SEC3

SCHEMA_FILE="$CLEARPATH_DIR/shared/schema.ts"

# Extract academy-related and assessment-related table blocks
TABLES="academy_certificates academy_builds academy_industry_content academy_sidebar_items assessment_questions assessment_results exercise_responses"

for table in $TABLES; do
  echo "### $table" >> "$OUTPUT_FILE"
  echo '```' >> "$OUTPUT_FILE"
  # Extract from pgTable definition to the closing ]);
  sed -n "/pgTable(\"${table}\"/,/^\]);/p" "$SCHEMA_FILE" >> "$OUTPUT_FILE"
  echo '```' >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
done

# Also extract the AcademyLessonContent interface
echo "### AcademyLessonContent (interface)" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
awk '
  /^export interface AcademyLessonContent/ { found=1 }
  found { print }
  found && /^}/ { found=0; exit }
' "$SCHEMA_FILE" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ─────────────────────────────────────────────
# Section 4: API Endpoints
# ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" <<'SEC4'
## 4. API Endpoints

SEC4

ROUTES_FILE="$CLEARPATH_DIR/server/routes/academy.ts"
echo '```' >> "$OUTPUT_FILE"
# Extract METHOD + path from route definitions using awk
awk '
  /app\.get\(/ { method="GET" }
  /app\.post\(/ { method="POST" }
  /app\.patch\(/ { method="PATCH" }
  /app\.delete\(/ { method="DELETE" }
  method != "" && match($0, /"\/[^"]*"/) {
    path=substr($0, RSTART+1, RLENGTH-2)
    print method " " path
    method=""
    next
  }
' "$ROUTES_FILE" >> "$OUTPUT_FILE"
echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ─────────────────────────────────────────────
# Section 5: Industry Content
# ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" <<'SEC5'
## 5. Industry Content

SEC5

INDUSTRY_FILE="$CLEARPATH_DIR/shared/academy-industry-content.ts"
echo "| Key | Label | Icon |" >> "$OUTPUT_FILE"
echo "|-----|-------|------|" >> "$OUTPUT_FILE"
grep -o '{ key: "[^"]*", *label: "[^"]*", *icon: "[^"]*" }' "$INDUSTRY_FILE" | \
  sed 's/.*key: "\([^"]*\)".*label: "\([^"]*\)".*icon: "\([^"]*\)".*/| \1 | \2 | \3 |/' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ─────────────────────────────────────────────
# Section 6: Tier Progression
# ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" <<'SEC6'
## 6. Tier Progression

| Tier | Modules | Pass Threshold | Min Behavioral Signals |
|------|---------|---------------|----------------------|
| Aware | 9 modules | 70% | 0 signals |
| Fluent | 8 modules | 80% | 3+ signals |
| Strategic | 8 modules | 80% | 10+ signals |
| Productivity | 6 modules | 70% | 0 (standalone) |

### Progression Flow
1. **Aware** (entry) - Complete all 9 modules + pass 70% assessment
2. **Fluent** - Complete all 8 modules + 3 behavioral signals + pass 80% assessment
3. **Strategic** - Complete all 8 modules + 10 behavioral signals + pass 80% assessment
4. **Productivity** - Standalone track, 6 modules, 70% pass (no signal requirement)
5. **Tool Guides** - Standalone per-tool tracks (e.g., Fireflies)
SEC6

echo "" >> "$OUTPUT_FILE"
echo "Done. Output: $OUTPUT_FILE"
