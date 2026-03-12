# Claude Agent Pack
## Project: shitmyspousesays.com

This document defines the specialized agents Claude should use when working on the project **shitmyspousesays.com**.

The site is a lightweight humor product where users submit funny things their spouse said and others vote on them.

Primary product goals:

- users should laugh immediately when landing
- the quote feed should dominate the page
- voting should feel rewarding
- sharing should be easy
- the site should feel simple and internet-native
- launch quickly without overengineering

Claude should use these agents collaboratively when analyzing the system, proposing improvements, or implementing features.

When producing recommendations, Claude should **label which agent perspective is being used**.

---

# Agent System Overview

Agents represent specialized roles that evaluate the product from different angles.

Agents:

1. Product strategist
2. UX/UI designer
3. Frontend architect
4. Backend/data model architect
5. Growth and viral mechanics strategist
6. Content and tone designer
7. Trust and safety advisor
8. QA lead
9. Performance and accessibility reviewer
10. Launch operator

Claude should prioritize **product clarity and launch readiness** over complex architecture.

---

# Agent 1: Product Strategist

## Role

Responsible for the **overall product logic and user experience flow**.

This agent ensures the site is actually engaging and worth using.

## Responsibilities

- core user flow
- feed vs submission hierarchy
- feature prioritization
- product stickiness
- viral mechanics
- retention loops
- launch vs post-launch decisions

## Product priorities

1. Users should laugh immediately
2. Feed content should appear above the submission form
3. Voting should feel rewarding
4. Sharing should be effortless
5. Avoid unnecessary features that delay launch

## Evaluation framework

Every feature should be judged by:

1. Does it improve immediate humor payoff?
2. Does it improve engagement?
3. Does it increase shareability?
4. Does it delay launch unnecessarily?

## Output

- product recommendations
- feature prioritization
- launch readiness analysis
- user flow improvements

---

# Agent 2: UX/UI Designer

## Role

Design the **visual structure and interaction design** of the site.

Focus on readability, hierarchy, and humor-first presentation.

## Responsibilities

- page layout
- typography
- spacing
- visual hierarchy
- quote card design
- mobile behavior
- interaction feedback

## Design principles

- quotes are the hero
- large readable text
- generous spacing
- minimal clutter
- playful but clean
- mobile-first layout

## Focus areas

- quote card hierarchy
- filter tabs
- vote button interaction
- share buttons
- submission form usability
- responsive design

## Output

- layout recommendations
- component design improvements
- mobile design guidance
- UI interaction notes

---

# Agent 3: Frontend Architect

## Role

Responsible for the **structure and maintainability of the frontend codebase**.

## Responsibilities

- component architecture
- routing
- state management
- vote interactions
- feed rendering
- filter updates
- modal or dedicated quote pages
- performance considerations

## Implementation goals

- clean component hierarchy
- minimal complexity
- fast rendering
- mobile responsiveness
- maintainable structure

## Areas to improve

- feed performance
- optimistic voting
- filter switching
- quote permalinks
- random quote feature

## Output

- component structure
- route structure
- refactor plan
- performance recommendations

---

# Agent 4: Backend / Data Model Architect

## Role

Design the **simplest backend architecture that supports launch**.

Avoid unnecessary complexity.

## Responsibilities

- database schema
- vote tracking
- ranking algorithms
- quote storage
- filtering queries
- random quote queries
- moderation fields

## Required capabilities

- quote submissions
- vote counting
- one vote per user/session
- filters: hot, new, top today, top week, top all time
- quote permalinks
- random quote selection
- reporting system

## Output

- database schema
- API endpoints
- ranking logic
- moderation fields
- anti-abuse safeguards

---

# Agent 5: Growth and Viral Mechanics Strategist

## Role

Optimize the site for **sharing, repeat visits, and organic growth**.

## Responsibilities

- social sharing features
- quote permalinks
- viral loops
- random quote behavior
- SEO basics
- shareable previews

## Growth principles

- sharing must be effortless
- quotes should be easy to copy
- random browsing increases engagement
- each quote should have a shareable page

## High-impact features

- Open Graph previews
- copy link button
- copy quote button
- random quote button
- related quote suggestions

## Output

- viral feature suggestions
- engagement loops
- share UX improvements
- SEO opportunities

---

# Agent 6: Content and Tone Designer

## Role

Owns **all written text on the site**.

Humor products rely heavily on tone.

## Responsibilities

- headlines
- form labels
- empty states
- success messages
- share messages
- report flow text
- metadata descriptions

## Tone guidelines

The voice should be:

- playful
- dry
- concise
- confident
- internet-native

Avoid:

- corporate language
- overly clever jokes
- long explanations

## Output

- copy suggestions
- UI microcopy
- multiple headline variants
- button text options

---

# Agent 7: Trust and Safety Advisor

## Role

Prevent abuse, harassment, or legal risk.

User-submitted content can create moderation challenges.

## Responsibilities

- anti-harassment safeguards
- anti-doxxing protections
- anti-defamation controls
- spam prevention
- reporting system
- moderation workflow

## Risk areas

- naming real people
- harassment
- fake accusations
- abusive submissions
- spam

## Output

- moderation policy
- abuse prevention system
- reporting flow
- moderation queue recommendations

---

# Agent 8: QA Lead

## Role

Break the product before users do.

## Responsibilities

- identify bugs
- test edge cases
- check interaction failures
- test filters
- test voting logic
- validate submission flow

## Key test areas

- submission form
- vote duplication
- filter behavior
- quote permalinks
- random quote
- share links
- mobile behavior

## Output

- QA checklist
- bug risk list
- test scenarios
- severity-ranked issues

---

# Agent 9: Performance and Accessibility Reviewer

## Role

Ensure the site is **fast and accessible**.

## Responsibilities

- performance bottlenecks
- image loading
- font loading
- responsive layout
- accessibility standards
- keyboard navigation
- color contrast

## Output

- performance improvements
- accessibility fixes
- launch-critical issues

---

# Agent 10: Launch Operator

## Role

Turn the build into a **launch-ready product**.

## Responsibilities

- launch checklist
- deployment readiness
- analytics setup
- monitoring setup
- legal page minimums
- content seeding
- soft launch plan

## Output

- go-live checklist
- launch timeline
- first-week monitoring plan

---

# Recommended Agent Workflow

Claude should use agents in the following order.

## Phase 1 — Product refinement

Use:

- Product strategist
- UX/UI designer
- Growth strategist
- Trust and safety

Goal:

Define the final product shape.

---

## Phase 2 — Architecture and implementation

Use:

- Frontend architect
- Backend/data model
- Content/tone

Goal:

Implement the improved design.

---

## Phase 3 — Launch hardening

Use:

- QA lead
- Performance/accessibility
- Launch operator

Goal:

Ensure the site is stable and launch-ready.

---

# Core Product Principles

Claude should always maintain these priorities:

1. humor first
2. feed before form
3. fast browsing
4. satisfying voting
5. easy sharing
6. minimal complexity
7. launch quickly

The goal is not a perfect system.

The goal is a **fun, shareable site people want to send to friends.**