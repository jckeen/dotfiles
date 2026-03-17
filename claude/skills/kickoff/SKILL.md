---
name: kickoff
description: Bootstrap a new project with proper structure, CLAUDE.md, changelog, and git init
user_invocable: true
---

When the user runs /kickoff, do the following:

1. Ask for: project name, brief description, and primary language/framework
2. Create this structure in the current directory:

```
<project-name>/
├── CLAUDE.md          # Project-specific instructions (build commands, conventions, architecture notes)
├── CHANGELOG.md       # Session log — updated at end of each work session
├── .gitignore         # Language-appropriate ignores
├── README.md          # Project name + one-line description
└── src/               # (or appropriate source directory for the framework)
```

3. Initialize git and make the first commit
4. The project `CLAUDE.md` should include:
   - Project description
   - Build/run/test commands (fill in once known)
   - Key architectural decisions (fill in as they're made)
   - A "Conventions" section for patterns to follow
5. The `CHANGELOG.md` should start with today's date and "Project created"
6. Ask the user if they want to create a GitHub repo (`gh repo create`)
