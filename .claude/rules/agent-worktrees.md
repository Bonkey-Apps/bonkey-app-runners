---
paths:
  - "**"
---

# Worker agents write only inside their own worktree

Every worker — `app-worker`, the `stage-*` pipeline agents, any subagent
dispatched to implement an issue — works in **its own `git worktree`**, cut
fresh off `origin/main`. The session's shared primary checkout
(`C:/Users/famla/Documents/Git/bonkey-apps/<repo>`) belongs to the orchestrator and is off limits.

```sh
cd C:/Users/famla/Documents/Git/bonkey-apps/<repo> && git fetch origin main
git worktree add -B <branch> C:/Users/famla/Documents/Git/bonkey-apps/wt-<slug> origin/main
cd C:/Users/famla/Documents/Git/bonkey-apps/wt-<slug> && pnpm install
```

## The assertion, before the first edit

```sh
# true only in a linked worktree — in the primary checkout the two are identical
test "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" \
  || echo 'STOP: this is the shared primary checkout, not a worktree'
git branch --show-current       # must be your own branch, not the orchestrator's
```

Prefer that test to comparing `git rev-parse --show-toplevel` against a
hardcoded path: it needs no knowledge of where the checkout lives, so it stays
correct for an agent dispatched against a sibling repo. If you are in the
primary checkout, stop and create the worktree first. This is cheap, and it is
the only thing standing between a routine fix and the failure below.

## What a worker never does to the shared checkout

- Edit, create or delete files in it
- `git add`, `git commit`, `git stash`, or amend anything in it
- `git checkout` / `git switch` — changing the branch under the orchestrator
- `git reset --hard`, `git clean -fdx`, `git gc --prune`, `git branch -D`,
  or any other destructive plumbing

## Why — the shared object store

Linked worktrees do **not** get their own object store: they all read and write
the one `.git` directory in the primary checkout. So a broad `git clean`,
`reset --hard`, `gc --prune` or branch deletion run in the shared repo does not
stay local — it can destroy commits another agent has made but not yet pushed,
in a worktree the destroying agent has never heard of. Uncommitted edits in the
shared tree are worse than useless besides: they sit on whatever branch the
orchestrator happens to be on, so the next stop hook or commit puts half of one
issue's fix onto an unrelated branch. That is exactly what happened on
2026-08-04 (BC-52, see BC-58).

## Cleaning up

Remove the worktree only after the branch is pushed, and only your own:
`git worktree remove C:/Users/famla/Documents/Git/bonkey-apps/wt-<slug>`. Never `git worktree prune` on
another agent's behalf — a worktree you don't recognize belongs to someone
still using it.

## Worktree paths and glob-based tools

Session worktrees land under `.claude/worktrees/`. That is a **harness default, not
our choice** — nobody opts in and you cannot decline it. On Windows it is enough to
silently break any tool that interpolates a root path into a glob.

### The mechanism

`jest-util`'s `replacePathSepForGlob`:

```js
return path.replace(/\\(?![{}()+?.^$])/g, '/');
```

`.` is in that negative lookahead, so a backslash immediately before a
dot-directory is **deliberately preserved**. `glob` then reads `\.` as an escaped
literal dot rather than a path boundary, and matches nothing:

```
under .claude  ->  ...\repo\.claude/worktrees/x/packages/store/**/*.test.ts   BROKEN
sibling wt-*   ->  ...\wt-BC-158/packages/store/**/*.test.ts                  ok
```

Any tool that builds a glob from an interpolated root is exposed; jest is just
where we found it.

### The dangerous failure is too WIDE, not zero — this rule said the opposite

An earlier version of this section claimed the suite "reports success having run
zero tests." **That is wrong**, and it pointed readers at the wrong failure mode.

**Zero discovery is loud.** jest exits **1** with `No tests found, exiting with
code 1`. It is only silent under `--passWithNoTests`, and none of the three
product repos sets that flag anywhere in their tracked trees — checked by
enumeration, not assumed.

The genuinely silent case is a **partial** fix. Repair `testMatch` but leave
`testPathIgnorePatterns` interpolating `<rootDir>`, and the ignore regex stops
matching — so suites that should be excluded leak in:

```
149 suites expected
172 suites discovered   <- 23 screenshot-harness suites leaked in, ALL GREEN
```

Too-wide-and-passing survives review far more easily than zero-and-failing.
Twenty-three extra green suites look like a *better* run to anyone skimming, and
nothing in the output says otherwise.

So when fixing this, fix **every** option that interpolates the root, not the one
that produced the ticket — `testMatch`, `testPathIgnorePatterns`,
`coveragePathIgnorePatterns`, `modulePathIgnorePatterns`, `roots`. A fix that
repairs one and leaves another turns a loud failure into a quiet one.

This is the count rule from `agent-liveness.md` arriving from above rather than
below: **any movement in a suite or test count is a failure until explained,
including movement upward.**

### And audit by family, not by remembered names

The fifth broken config in that repo was `apps/mobile/jest.screenshots.js`. It
escaped an audit that grepped `jest.config*` — **because of its filename.**

The audit had the same defect as the bug it was auditing for: a pattern that
looked exhaustive and silently matched a subset. Match the family (`**/jest.*.js`)
rather than the names you happen to remember. The same correction was needed on
an eslint glob in the same repo, for the same reason.

### The rule

**Never interpolate a root path into a glob.** Express discovery with `roots` —
paths, which are never glob-converted — plus a `rootDir`-relative pattern:

```js
roots: [__dirname],                 // NOT `${__dirname}/src`; see BM-54
testMatch: ["**/*.test.{ts,tsx}"],  // no <rootDir> token
```

Reference implementation: `bonkey-math-app`, BM-54, which ships a companion test
asserting no `<rootDir>` token survives into any glob.

Proven dead end — do not spend time here: **normalizing `rootDir` does not work.**
jest re-resolves it to a platform path before interpolation.

### Do not try to fix this with worktree location

"Keep worktrees out of dot-directories" is not a fix, because the location is not
ours to choose. Sibling `wt-<slug>` worktrees are safe by accident, not by policy —
a repo whose workers happen to use them is one dispatch away from the defect.

Fix the config. It holds wherever the checkout lives.

### Detecting it

Two conditions, and **both** must hold:

| | question | how to answer |
| --- | --- | --- |
| **exposed** | does a config interpolate the root into a glob? | grep |
| **live** | does the checkout path contain a dot-directory? | inspect the path |

Grep answers only the first. Two traps in it:

- **Grep for the token, then read the config.** The token can be assigned to a
  constant and consumed in `projects[]`, so `testMatch.*<rootDir>` misses it.
- **`roots` being set is not a mitigation.** A config can look safe because it sets
  `roots` and still be broken if `testMatch` also interpolates. Check the globs, not
  the presence of a mitigation.

**Symptom to watch for: the count, in BOTH directions.** Treat any movement in a
suite or test count as a failure until explained. A suite that silently loses 21
tests and reports 1058 passing looks like success in a way that 0 never does —
and a partial fix that discovers **172 suites where 149 were expected**, all
green, looks like an improvement. Zero is the one case that announces itself
(jest exits 1); every other count is on you to notice.
