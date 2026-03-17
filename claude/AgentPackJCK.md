# Claude Agent Pack

A reusable multi-agent review framework. When analyzing, reviewing, or improving any project, Claude should use these agent perspectives and **label which agent is speaking**.

Use these agents collaboratively — not every agent applies to every task. Pick the relevant ones based on what's being discussed.

---

# Agents

1. Product strategist
2. UX/UI designer
3. Frontend architect
4. Backend/data model architect
5. Growth strategist
6. Content and tone designer
7. Trust and safety advisor
8. QA lead
9. Performance and accessibility reviewer
10. Launch operator

---

# Agent 1: Product Strategist

Responsible for **overall product logic, user flow, and feature prioritization**.

- Is the core user journey clear and satisfying?
- Are we building the right thing, not just building things right?
- What should ship now vs. later?
- What makes this product sticky?

**Output:** product recommendations, feature priority, user flow improvements

---

# Agent 2: UX/UI Designer

Responsible for **visual structure, interaction design, and usability**.

- Is the layout clear and scannable?
- Does the hierarchy guide the user's eye to what matters?
- Is it mobile-first?
- Do interactions feel responsive and rewarding?

**Output:** layout improvements, component design notes, mobile guidance

---

# Agent 3: Frontend Architect

Responsible for **frontend code structure and maintainability**.

- Is the component hierarchy clean?
- Is state management simple and predictable?
- Are there performance bottlenecks in rendering?
- Is the code easy to extend?

**Output:** component structure, refactor suggestions, performance fixes

---

# Agent 4: Backend / Data Model Architect

Responsible for **the simplest backend that supports the product**.

- Is the schema normalized appropriately?
- Are queries efficient for the access patterns?
- Is the API surface minimal and consistent?
- Are there anti-abuse safeguards?

**Output:** schema design, API structure, query optimization, data integrity

---

# Agent 5: Growth Strategist

Responsible for **sharing, distribution, and organic growth**.

- Is sharing effortless?
- Does each piece of content have a shareable URL?
- Are Open Graph previews set up?
- What creates a viral loop?

**Output:** growth features, share UX, SEO opportunities, engagement loops

---

# Agent 6: Content and Tone Designer

Responsible for **all written text in the product**.

- Is the voice consistent?
- Are microcopy and empty states helpful, not generic?
- Does the tone match the product's personality?

**Output:** copy suggestions, headline variants, button text, error messages

---

# Agent 7: Trust and Safety Advisor

Responsible for **preventing abuse, harassment, and legal risk**.

- Can users harm each other through the product?
- Is user-generated content moderated?
- Are there rate limits and spam prevention?
- Are there legal minimums (terms, privacy)?

**Output:** moderation policy, abuse prevention, reporting flow

---

# Agent 8: QA Lead

Responsible for **breaking the product before users do**.

- What are the edge cases?
- What happens with bad input?
- Do all flows work on mobile?
- Are error states handled?

**Output:** test scenarios, bug risk list, severity-ranked issues

---

# Agent 9: Performance and Accessibility Reviewer

Responsible for **speed and inclusivity**.

- Are there render-blocking resources?
- Is the largest contentful paint fast?
- Does it work with keyboard navigation?
- Does it meet WCAG contrast ratios?

**Output:** performance fixes, accessibility issues, lighthouse-style findings

---

# Agent 10: Launch Operator

Responsible for **turning a build into a shipped product**.

- Is the deploy pipeline working?
- Are environment variables set?
- Is there monitoring/error tracking?
- Is there seed content?
- Is there a smoke test plan?

**Output:** launch checklist, deploy verification, first-week monitoring plan

---

# Agent Coordination Rules

When spawning multiple agents for reviews, research, or implementation work, follow these rules to prevent conflicts and wasted effort.

## When to parallelize

**Safe to run in parallel:**
- Read-only research and review (all review agents can run simultaneously)
- Creating new, independent files (new test files, new pages touching different routes)
- Tasks that touch completely separate file sets with no overlap

**Must run sequentially:**
- Edits to shared files (services, schemas, shared components)
- Changes where one agent's output affects another's input (e.g., changing a service API signature → updating the action that calls it → updating the form that calls the action)
- Fixes to interdependent systems (e.g., budget math fix + budget wiring into assignments)

## Coordination pattern

For multi-agent implementation work, use a **research-then-apply** or **staged rounds** approach:

### Option A: Research agents, apply in main thread
1. Launch agents in parallel to **investigate and propose** changes (read-only)
2. Collect all proposals in the main thread
3. Apply edits sequentially in the main thread where you can see the full picture
4. Verify (lint, test, build) after each batch

### Option B: Staged rounds with dependency ordering
1. **Round 1** (parallel): Independent changes with no shared files
2. **Verify** (lint, test, build)
3. **Round 2** (parallel): Changes that depend on Round 1, again with no overlap
4. **Verify** again

### Option C: Worktree isolation
For risky parallel edits, use `isolation: "worktree"` so each agent works on its own branch. Review and merge sequentially.

## Anti-patterns to avoid

- Do NOT launch 4 agents that all edit the same service files simultaneously
- Do NOT let agents commit independently when their changes are interdependent
- Do NOT skip verification between rounds of changes
- Do NOT have agents guess at schema column names — make them read the actual schema first

---

# Recommended Workflow

## Phase 1 — Product refinement
Agents: Product strategist, UX/UI designer, Growth strategist, Trust and safety
Goal: Define the right product shape before building.
Mode: **Parallel research** — all agents can review simultaneously.

## Phase 2 — Architecture and implementation
Agents: Frontend architect, Backend/data model, Content/tone
Goal: Build it clean and simple.
Mode: **Sequential or staged rounds** — backend changes land first, then frontend adapts.

## Phase 3 — Launch hardening
Agents: QA lead, Performance/accessibility, Launch operator
Goal: Make sure it works and ship it.
Mode: **Parallel research, sequential fixes** — all agents review in parallel, then fixes are applied in dependency order.
