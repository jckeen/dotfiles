## 2026-10-19 — feat(hooks): operator-action items live in the repo they concern

- **`claude/hooks/OperatorQueueReminder.hook.sh`**: the issue source is now one
  GraphQL search over the private home repo (`OPERATOR_QUEUE_REPO`, default
  `jckeen/claude-memory`) plus every repo of the `OPERATOR_QUEUE_OWNERS`
  accounts (default `jckeen Keen-Media therealnewsnetwork`; empty = home repo
  only). Owner values keep only GitHub login characters, so none can add a
  qualifier to the query. Because the items enter every session's context,
  only issues the operator wrote (`author:@me`) in private repos count, in the
  query and again in jq (`viewerDidAuthor`, `repository.isPrivate`): a
  stranger's issue in a public repo, a collaborator's, or one whose body
  someone else last edited or whose title someone else last renamed (GitHub's
  `editor` does not track renames) never renders. A refresh fails, rather
  than caching a partial list, when the search hits GitHub's 1000-result cap
  or the gh account changes while it runs.
  Each heading names its repo (`<slug> (<repo>#<n>)`).
  With no body `project:` line, an issue outside the home repo takes its repo
  name as its project; labels count only in the home repo and only as a plain
  `project:<slug>`, since any collaborator can write a label. The owners are part of the cache key, which is
  versioned, so a cache written before these filters is never rendered, and
  carries a digest of the gh identity (token variables and `hosts.yml`, read
  locally), so switching gh accounts never shows another account's items.
  `OPERATOR_QUEUE_REPO` must be one plain `[host/]owner/name` (anything else
  refuses the issue source with one line), and at most ten owners are kept,
  so the scope in status lines stays bounded. Messages and
  the footer name the whole scope and print the hook's own search as a runnable
  `gh api graphql` command (`gh search issues --repo --owner` would AND them).
- Data move, 2026-10-19 (one-shot, run from a session; the queue file was
  the source of truth): 64 items moved from `jckeen/claude-memory` to 12
  private repos (their claude-memory issues closed "not planned" with a link
  to the new issue). 21 stay in claude-memory (dotfiles and agent-pack are
  public; fleet items span several repos). 2 were refreshed from the file and
  2 that were already done were closed.
- Antigravity's write permission for the retired queue file is removed.
