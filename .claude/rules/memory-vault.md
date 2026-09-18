---
paths:
  - "**"
---

# The memory vault — read it first, write back what lasts

Every agent in this repo has access to **`bonkey-memories`**, an Obsidian
vault kept as plain markdown in git
(`https://github.com/bonkey-apps/bonkey-memories`, normally cloned to
`/workspace/bonkey-memories`).

It exists because these containers are ephemeral. Everything an agent
learns the hard way — which command actually works, which test is flaky
and why, which approach was already tried and abandoned — dies with the
container unless it is written down somewhere that outlives it. The vault
is that somewhere.

## Read before you explore

At the start of non-trivial work, check the vault for what's already
known:

```sh
V=/workspace/bonkey-memories
[ -d "$V/.git" ] || echo "vault not cloned — see below"
ls "$V/reference/repos/"
git -C "$V" grep -l -- '<topic>'
```

`git grep` rather than `rg` on purpose: the vault is always a git clone, so
git is guaranteed present, and it searches tracked files only — which is
what you want here anyway. Keep the `--`: without it a topic starting with
`-` is parsed as a flag, and you get `unknown switch` instead of results.

`reference/repos/<this-repo>.md`, when it exists, is the fastest
orientation available — it carries verified commands, the architecture
map, and the gotchas list. Reading it costs seconds; rediscovering its
contents costs a session. If it's missing or stale, the `learn-repo`
skill in the vault builds or refreshes it.

If the vault isn't cloned in this session, some repos ship
`scripts/setup-obsidian.sh`, which clones it (and installs Obsidian); it is
idempotent and needs root. For just the vault:

```sh
git clone --depth 1 https://github.com/bonkey-apps/bonkey-memories /workspace/bonkey-memories
```

**If that clone fails, the vault's silence is UNKNOWN prior knowledge, not
ABSENT prior knowledge.** A failed read does not mean nothing was learned
before — it means you can't see it. Say so explicitly in your report, work
more cautiously than you would with a clean vault (assume a gotcha you'd
normally be warned about might be waiting), and retry or ask rather than
treating the failure as a green light to proceed as if the vault were empty.

## Write back what the next agent would want

Before finishing, ask whether you learned anything that isn't recoverable
by reading the code. If yes, write it down:

- A command that didn't work the documented way, and what does
- A flaky test, its symptom, and whether it was fixed or just rerun
- An approach that was tried and rejected, and why — this is the one
  that saves the most duplicated effort
- A non-obvious coupling between packages that bit you
- Anything you had to ask the owner about, and the answer

File it per the vault's `CLAUDE.md`: durable topic notes in `notes/`,
repo maps in `reference/repos/`, a session log line in `daily/`.

**Then commit and push.** An unpushed note doesn't exist — the container
is reclaimed and takes it with it. This is the most common way vault work
is lost, and unlike code there is no CI failure to make the omission
visible.

## What does *not* go in the vault

The vault is a memory aid, not a second system of record. Putting
authoritative content there splits the truth across two places and makes
both untrustworthy.

| Belongs in                | Not the vault                                    |
| ------------------------- | ------------------------------------------------ |
| `docs/adr/`               | Architecture decisions for this repo             |
| The repo's own docs tree  | Canonical specs the code implements              |
| The repo's Jira project   | Work item status, scope, acceptance              |
| GitHub PRs                | Code review discussion                           |
| This repo's `CLAUDE.md`   | Conventions that bind agents working here        |
| `.claude/rules/`          | Area-specific rules, including this one          |

Each repo names its own docs tree and Jira project in its `CLAUDE.md` —
`docs/games/` and `BC` for Cards, `docs/content/` and `BP` for Puzzles,
`docs/design/` + `docs/compliance/` and `BM` for Math. Read that rather
than assuming; this file deliberately does not restate it, because a
shared rule that hardcodes one product's paths is how these copies drifted
apart in the first place.

The vault holds the *cross-session working knowledge* around those —
notes, orientation, gotchas, dead ends — and links out to the
authoritative source rather than restating it. When a note and a decision
doc disagree, the doc is right and the note needs fixing.

**Never put secrets in it.** Tokens, keys, `.env` contents, internal
hostnames — the vault is plain text in a git repo. Record that a
credential is needed and where it comes from, never its value.

## Worker agents

The vault is a separate repo, so the worktree isolation your repo enforces
does not apply to it — a worker may commit and push vault notes directly
on the vault's default branch while its own code change stays confined to
its worktree. Keep the two commits separate; a vault note is never part of
a code PR.
