# Academy Context — Auto-Generated

> Auto-generated on Sat Mar 28 21:15:29 PDT 2026. Do not edit manually.

## 1. Module Inventory

### aware

| Key | Title | Named Concept | Tier |
|-----|-------|---------------|------|
| aware_01_ai-already-in-your-life | AI Is Already in Your Life | The AI You Already Use | aware |
| aware_02_how-people-use-ai | How People Are Using AI Right Now | The AI Landscape | aware |
| aware_03_how-to-talk-to-ai | How to Talk to AI | The Five-Part Instruction | aware |
| aware_04_the-confidence-gap | The Confidence Gap | The Confidence Gap | aware |
| aware_05_what-not-to-share | What Not to Share | The Traffic Light System | aware |
| aware_06_inputs-shape-outputs | Inputs Shape Outputs | Curated Input | aware |
| aware_07_ai-doesnt-remember-you | AI Doesn't Remember You | The Persistent Context Document | aware |
| aware_08_ai-as-assistant | AI as Your Assistant | The Delegation Spectrum | aware |
| aware_09_your-ai-baseline | Your AI Baseline | Competency Self-Assessment | aware |

### fluent

| Key | Title | Named Concept | Tier |
|-----|-------|---------------|------|
| fluent_01_advanced-prompting | Advanced Prompting Techniques | The Instruction Architecture | fluent |
| fluent_02_research-analysis | AI for Research & Analysis | The Research Accelerator | fluent |
| fluent_03_communication | AI-Powered Communication | The Draft Partner | fluent |
| fluent_04_finding-patterns | AI for Finding Patterns | The Pattern Lens | fluent |
| fluent_05_meetings-presentations | AI for Meetings & Presentations | The Preparation Engine | fluent |
| fluent_06_decision-support | AI for Decision Support | The Devil's Advocate | fluent |
| fluent_07_building-workflows | Building AI Workflows | The Automation Mindset | fluent |
| fluent_08_your-playbook | Your AI Playbook | The Personal AI Operating System | fluent |

### strategic

| Key | Title | Named Concept | Tier |
|-----|-------|---------------|------|
| strategic_01_user-to-champion | From User to Champion | The AI Champion Playbook | strategic |
| strategic_02_governance | AI Governance That Works | The Practical Guardrails | strategic |
| strategic_03_ai-goes-wrong | When AI Goes Wrong | The Failure Protocol | strategic |
| strategic_04_getting-buy-in | Getting Buy-In | The Show-Don't-Tell Method | strategic |
| strategic_05_collaborative-ai | Collaborative AI | The Shared Intelligence System | strategic |
| strategic_06_proving-value | Proving AI's Value | The Before & After Snapshot | strategic |
| strategic_07_ai-strategy | Your AI Strategy | The Use Case Canvas | strategic |
| strategic_08_maturity-assessment | The AI Maturity Assessment | The AI Maturity Scorecard | strategic |

### productivity

| Key | Title | Named Concept | Tier |
|-----|-------|---------------|------|
| prod_01_setup_command_center | Set Up Your AI Command Center | The Personal AI Architecture | productivity |
| prod_02_ai_landscape | The AI Landscape: Which Tool for Which Job | The Two Gravitational Centers Framework | productivity |
| prod_03_audit_your_week | Audit Your Week: Find 10 Hours to Reclaim | The Productivity Audit | productivity |
| prod_04_your_first_workflow | Your First Workflow: Build a Real Automation | The Staged Build Approach | productivity |
| prod_05_your_ai_toolkit | Your AI Toolkit: Voice, Knowledge, and Output | The Capture-Process-Ship System | productivity |
| prod_06_your_productivity_system | Your Productivity System: Process Over Tools | The Two Gravitational Centers System | productivity |

### tool-guide

| Key | Title | Named Concept | Tier |
|-----|-------|---------------|------|
| tg_fireflies_01_what-is-fireflies | What Is Fireflies | The AI Meeting Assistant | aware |
| tg_fireflies_02_dashboard-access | Navigating the Dashboard | The Dashboard Command Center | aware |
| tg_fireflies_03_ai-notes | AI Notes & Smart Summaries | Smart Summary Architecture | aware |
| tg_fireflies_04_custom-templates | Custom Summary Templates | Template-Driven Intelligence | aware |
| tg_fireflies_05_salesforce-integration | Salesforce Integration | CRM Auto-Intelligence | aware |
| tg_fireflies_06_credits-usage | Credits & Usage | The Credit Economy | aware |
| tg_fireflies_07_privacy-best-practices | Privacy & Best Practices | Recording Ethics & Data Responsibility | aware |

## 2. File Map

### shared/ (content definitions)
```
shared/academy-industry-content.ts
shared/academy-modules.ts
shared/academy-research-feed.md
shared/aware-modules.ts
shared/fluent-modules.ts
shared/productivity-modules.ts
shared/strategic-modules.ts
shared/tool-guide-modules.ts
```

### server/ (routes, storage, seeds)
```
server/routes/academy.ts
server/seed-academy-industry.ts
server/seed-academy.ts
server/storage/academy.ts
```

### client/src/pages/ (academy pages)
```
client/src/pages/academy-admin.tsx
client/src/pages/academy-course.tsx
client/src/pages/academy-module.tsx
client/src/pages/academy-playbook.tsx
client/src/pages/academy.tsx
```

### client/src/components/academy/ (components)
```
client/src/components/academy/AcademySidebarItemSaver.tsx
client/src/components/academy/IndustryTabSection.tsx
client/src/components/academy/framework-diagrams.tsx
client/src/components/academy/lesson-drawer.tsx
client/src/components/academy/lesson-step-viewer.tsx
client/src/components/academy/lesson-text-renderer.tsx
```

## 3. Database Tables

### academy_certificates
```
export const academyCertificates = pgTable("academy_certificates", {
  id: serial("id").primaryKey(),
  orgId: text("org_id").notNull(),
  userId: varchar("user_id").notNull(),
  tierId: text("tier_id").notNull(), // 'aware' | 'fluent' | 'strategic'
  userName: text("user_name").notNull(),
  courseName: text("course_name").notNull(),
  issuerName: text("issuer_name").notNull().default("Clearpath"),
  badgeId: varchar("badge_id").notNull().unique(), // UUID
  assessmentScore: integer("assessment_score").notNull().default(0),
  assessmentResultId: integer("assessment_result_id"),
  issuedAt: timestamp("issued_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
}, (table) => [
  index("idx_academy_certs_org").on(table.orgId),
  index("idx_academy_certs_user").on(table.userId),
]);
```

### academy_builds
```
export const academyBuilds = pgTable("academy_builds", {
  id: serial("id").primaryKey(),
  orgId: varchar("org_id").notNull(),
  userId: varchar("user_id").notNull(),
  moduleKey: varchar("module_key").notNull(),
  moduleNumber: integer("module_number").notNull(),
  buildData: jsonb("build_data").notNull().default({}),
  fieldCount: integer("field_count").notNull().default(0),
  createdAt: timestamp("created_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
  updatedAt: timestamp("updated_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
}, (table) => [
  index("idx_academy_builds_org_user").on(table.orgId, table.userId),
  uniqueIndex("idx_academy_builds_unique").on(table.orgId, table.userId, table.moduleKey),
]);
```

### academy_industry_content
```
export const academyIndustryContent = pgTable("academy_industry_content", {
  id: serial("id").primaryKey(),
  moduleKey: varchar("module_key").notNull(),
  industryKey: varchar("industry_key").notNull(),
  industryLabel: varchar("industry_label").notNull(),
  scenario: text("scenario").notNull(),
  realQuote: text("real_quote"),
  quoteAttribution: varchar("quote_attribution"),
  quoteSource: varchar("quote_source"),
  roleLenses: jsonb("role_lenses").notNull().default([]),
  tryItPrompt: text("try_it_prompt").notNull(),
  orgId: varchar("org_id"),
  sourceExtractionIds: jsonb("source_extraction_ids").default([]),
  createdAt: timestamp("created_at").defaultNow(),
  updatedAt: timestamp("updated_at").defaultNow(),
}, (table) => [
  index("idx_industry_content_module_industry").on(table.moduleKey, table.industryKey),
  index("idx_industry_content_org").on(table.orgId),
  uniqueIndex("idx_industry_content_unique").on(table.moduleKey, table.industryKey, table.orgId),
]);
```

### academy_sidebar_items
```
export const academySidebarItems = pgTable("academy_sidebar_items", {
  id: serial("id").primaryKey(),
  orgId: varchar("org_id").notNull(),
  userId: varchar("user_id").notNull(),
  itemType: varchar("item_type").notNull(),   // "custom_instructions" | "workflow" | "ai_system_doc"
  title: varchar("title").notNull(),
  content: text("content").notNull(),
  sourceModuleKey: varchar("source_module_key"),
  metadata: jsonb("metadata").default({}),
  createdAt: timestamp("created_at").defaultNow(),
  updatedAt: timestamp("updated_at").defaultNow(),
}, (table) => [
  index("idx_sidebar_items_org_user").on(table.orgId, table.userId),
]);
```

### assessment_questions
```
export const assessmentQuestions = pgTable("assessment_questions", {
  id: serial("id").primaryKey(),
  orgId: text("org_id").notNull(),
  tierId: text("tier_id").notNull(), // 'aware' | 'fluent' | 'strategic'
  moduleKey: text("module_key"), // nullable — ties to specific module
  question: text("question").notNull(),
  options: jsonb("options").$type<{ id: string; text: string }[]>().notNull().default([]),
  correctAnswer: text("correct_answer").notNull(), // option id
  explanation: text("explanation").notNull().default(""),
  sortOrder: integer("sort_order").notNull().default(0),
  createdAt: timestamp("created_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
}, (table) => [
  index("idx_assessment_questions_org_tier").on(table.orgId, table.tierId),
]);
```

### assessment_results
```
export const assessmentResults = pgTable("assessment_results", {
  id: serial("id").primaryKey(),
  orgId: text("org_id").notNull(),
  userId: integer("user_id").notNull(),
  tierId: text("tier_id").notNull(),
  scenarioScore: integer("scenario_score").notNull().default(0),
  scenarioPassed: boolean("scenario_passed").notNull().default(false),
  actionsPassed: boolean("actions_passed").notNull().default(false),
  behavioralPassed: boolean("behavioral_passed").notNull().default(false),
  passed: boolean("passed").notNull().default(false),
  answers: jsonb("answers").$type<Record<string, string>>().notNull().default({}),
  feedback: text("feedback"),
  attemptNumber: integer("attempt_number").notNull().default(1),
  createdAt: timestamp("created_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
}, (table) => [
  index("idx_assessment_results_org_user").on(table.orgId, table.userId),
]);
```

### exercise_responses
```
export const exerciseResponses = pgTable("exercise_responses", {
  id: serial("id").primaryKey(),
  orgId: varchar("org_id").notNull(),
  userId: varchar("user_id").notNull(),
  moduleKey: varchar("module_key").notNull(),
  responses: jsonb("responses").$type<string[]>().default([]),
  createdAt: timestamp("created_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
  updatedAt: timestamp("updated_at").default(sql`CURRENT_TIMESTAMP`).notNull(),
}, (table) => [
  index("idx_exercise_responses_org_user").on(table.orgId, table.userId),
  uniqueIndex("idx_exercise_responses_unique").on(table.orgId, table.userId, table.moduleKey),
]);
```

### AcademyLessonContent (interface)
```
export interface AcademyLessonContent {
  storyHook: string;
  namedConcept: string;
  conceptEquation: string;
  whatItIs: string;
  whyItMatters: string;
  seeItInYourData: {
    promptKey: string;
    fallbackText: string;
    instructionText: string;
  };
  tryItAction: {
    description: string;
    actionUrl: string;
    completionVerb: string;
    persistArtifact?: {
      itemType: "custom_instructions" | "workflow" | "ai_system_doc";
      titlePrompt: string;
      placeholder: string;
    };
  };
  securityThroughline?: string;
  euAiActMapping?: string;
  // Long-form 5-section content for Academy reading experience
  story?: string;
  framework?: string;
  yourData?: string;
  tryIt?: string;
  security?: string;
  industryTabEnabled?: boolean;  // default true — allows disabling per module
}
```

## 4. API Endpoints

```
GET /api/academy/modules
GET /api/academy/modules/:key
POST /api/academy/modules/:key/complete
POST /api/academy/modules/:key/time
GET /api/academy/modules/:key/exercises
POST /api/academy/modules/:key/exercises
DELETE /api/academy/modules/:key/build
GET /api/academy/playbook/pdf
GET /api/academy/playbook
GET /api/academy/tier-status
GET /api/academy/assessment/results
GET /api/academy/assessment/:tierId
POST /api/academy/assessment/:tierId/submit
GET /api/academy/certificates/:id
GET /api/academy/certificates/:id/download
GET /api/admin/academy/compliance-report
GET /api/academy/summary
GET /api/academy/goals
PATCH /api/academy/goals
GET /api/admin/academy/stats
GET /api/academy/aware
GET /api/admin/academy/assessment/:tierId/questions
POST /api/admin/academy/assessment/:tierId/questions
PATCH /api/admin/academy/assessment/:tierId/questions/:id
DELETE /api/admin/academy/assessment/:tierId/questions/:id
POST /api/academy/sandbox/message
GET /api/academy/industries
GET /api/academy/industry-content/:moduleKey
POST /api/academy/industry-content
GET /api/academy/sidebar-items
POST /api/academy/sidebar-items
DELETE /api/academy/sidebar-items/:id
PATCH /api/academy/industry-preference
```

## 5. Industry Content

| Key | Label | Icon |
|-----|-------|------|
| msp | In Your MSP | server |
| nonprofit | In Your Nonprofit | heart |
| aec | In Your Firm | building |
| legal | In Your Practice | scale |
| realestate | In Your Portfolio | home |
| proserv | In Your Agency | briefcase |

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

