---
paths:
  - "**"
---

# A stage is done when its artifact exists — not when the agent says so

This is the single source for the anti-stall rule. Every dispatched agent
inherits it — `app-worker`, `stage-implement`, `stage-code-review`,
`stage-deploy`, `pr-shepherd`, any subagent handed a piece of work — and so does
every caller that dispatches one. The stage skills and agent definitions point
here rather than restating it; when one of them disagrees with this file, this
file wins.

It has two halves, because the failure has two halves. **Prevention** is the
agent's: deliver an artifact, never stop short of it. **Detection** is the
caller's: verify the artifact, never trust a report or a board status.

## What went wrong, twice

**2026-08-04 (BC-58, BC-62).** Ten dispatched agents stalled across all three
stages and two repos. Six ended their turn announcing a wait — "waiting for the
background test run", "standing by for the CI monitor" — and nothing ever woke
them. **Four never emitted a completion notification at all.** They sat
indefinitely; the board read In Review, the branches existed, nothing was red,
and no event ever arrived. Probing them returned `had no active task; resumed
from transcript in the background` — they had been dead the whole time. The
orchestrator only found them by inspecting git state: three branches still at
their stage-1 SHAs, two worktrees holding uncommitted work.

**2026-08-06 (BC-28).** A worker pushed its branch at `5046eb9` with every gate
green, commented its full findings on the Jira issue, transitioned the issue to
In Review — and stopped **without opening the PR**. It sat finished-but-
undelivered for roughly twelve hours. Two compounding causes, both worth
generalizing:

1. The dispatch prompt said _"do not arm auto-merge on the PR"_ — correct, it
   was a decision doc. The worker read it as _"do not open the PR."_
2. The orchestrator treated the Jira transition to In Review as evidence a PR
   existed, and never checked.

A stall that notifies is recoverable. A **silent** stall is invisible, and
unattended it means the run stops partway and reports nothing wrong — strictly
worse than failing loudly.

---

# Half 1 — for the agent: deliver the artifact

## Your deliverable is an artifact, not a description of one

Each stage has exactly one thing that proves it happened. Nothing else counts —
not a green gate, not a clean diff, not a comment, and **not a board status**.

| Stage / role                        | The artifact that proves it happened                      |
| ----------------------------------- | --------------------------------------------------------- |
| `stage-implement`                   | the branch on the remote, with commits beyond `main`       |
| `stage-code-review`                 | the branch on the remote at a **new SHA**                  |
| `stage-deploy`, `pr-shepherd`       | the PR open against `main` (then: merged)                  |
| `app-worker`                        | the branch pushed **and** the PR open                      |

Work that exists only in a worktree has not been delivered. Before your final
message, satisfy and state the outcome of each of these:

- [ ] you are in your own worktree, not the shared primary checkout
      (`.claude/rules/agent-worktrees.md`)
- [ ] `git status --porcelain` is empty — `git add` anything showing `??` first;
      an untracked new test file is in no commit and vanishes with the worktree
- [ ] commits exist beyond the base (`git log --oneline origin/main..HEAD`)
- [ ] `git push -u origin <branch>` succeeded and the ref is on the remote
- [ ] the stage's own artifact above exists (for a PR stage: the PR is open)
- [ ] the tracker moved — **last**, after the artifact exists, never before

Anything unchecked means the stage failed. Say so plainly; a caller that finds
out for itself has already lost the time.

## Gates run synchronously, in the foreground

Run `pnpm typecheck && pnpm lint && pnpm format:check && pnpm test` inline and
read the output. **Never** background a gate, and never end a turn waiting on a
monitor, a notification, or a background task — nothing wakes you: the turn
ends, the work stays uncommitted, and the worktree is eventually reclaimed with
the diff still in it.

These are real turn endings from the 2026-08-04 run. Every one is a stall. **Do
not end a turn like any of these:**

> - "Waiting for the background test run to finish before proceeding."
> - "I'll wait for the monitor to notify me that the test output has stabilized."
> - "I've kicked off the full `pnpm test` gate in the background and am
>   monitoring it for completion. I'll report full results once it finishes."
> - "I'll pause here and wait for the test run notification before continuing."
> - "I'll stop here and wait for the background test run's Monitor notification
>   before proceeding." _(stage 2)_
> - "Standing by for the CI monitor and PR webhook activity." _(stage 3)_

The last two matter especially: stage 2 and stage 3 stall exactly like stage 1
does. A CI wait is not an exception — re-check on your own initiative instead of
ending the turn, because webhooks do not reliably deliver CI success, new
pushes, or merge-conflict transitions.

**Never report a gate green without having watched it pass.** "Presumably
green", "should pass" and "kicked off" are not results. If the suite is
genuinely too slow to run inline, narrow it — the affected package's tests plus
root `typecheck` / `lint` / `format:check` — and name in your report exactly
what you ran and what you skipped. A narrowed, honest gate is a legitimate
outcome; silently waiting is not.

## A prohibition never subtracts the deliverable

This is the BC-28 trap, and it generalizes past auto-merge. A dispatch prompt
that restricts what you may do **to** an artifact is never permission to skip
**creating** it:

| The instruction                        | Means                                    | Does **not** mean          |
| -------------------------------------- | ---------------------------------------- | -------------------------- |
| "do not arm auto-merge"                | open the PR, leave it for a human to merge | don't open the PR          |
| "open it as a draft"                   | open the PR, in draft                    | don't open the PR          |
| "do not merge it yourself"             | open the PR, let auto-merge land it      | don't open the PR          |
| "do not touch file X"                  | leave X alone, ship everything else      | don't ship                 |
| "the owner approves this one"          | open the PR and stop there               | don't open the PR          |

If a prompt genuinely seems to forbid producing your stage's artifact, that is a
contradiction in the prompt, not an instruction to stop quietly. Say so to your
caller and stop — visibly.

## Callers: write the definition of done in artifact terms

When you dispatch, state the DoD as artifacts and put every restriction
**inside** the step it qualifies, never as a free-floating "do not …":

> You are not done when the branch is pushed. You are done when (1) the branch
> is pushed, (2) a PR is open against `main`, and (3) you have reported the PR
> number back. Open the PR as a draft and do not arm auto-merge — the owner
> merges this one. "Do not arm auto-merge" is a restriction on the PR, not
> permission to skip opening it.

---

# Half 2 — for the caller: verify the artifact, poll, don't wait

## A board status is not a deliverable

Jira status and the agent's own report are **self-reported by the very agent
that might have stalled** — they are exactly the wrong things to trust as a
completion signal. Notifications are a best-effort optimization, not a
guarantee: four agents in one run produced none at all. Ground truth is the
artifact on the remote and the state of the worktree, and nothing else.

**Never advance an issue, and never call a run finished, on a report or a status
alone.**

## Check it mechanically

`scripts/check-stage-artifacts.mjs` is the check — run it instead of
re-improvising a prose one:

```sh
# stage 1: branch pushed with real commits, worktree clean
node scripts/check-stage-artifacts.mjs --stage implement \
  --branch BC-56-kings-corner-hand-fan --worktree C:/Users/famla/Documents/Git/bonkey-apps/wt-bc56

# stage 2: the head must have MOVED past what stage 1 left
node scripts/check-stage-artifacts.mjs --stage review \
  --branch BC-56-kings-corner-hand-fan --worktree C:/Users/famla/Documents/Git/bonkey-apps/wt-bc56 \
  --since-sha <stage-1 head SHA>

# stage 3: a PR whose head is this branch. Pass --worktree here too — stage 3
# pushes CI fixes, so it can leave uncommitted work like any other stage.
node scripts/check-stage-artifacts.mjs --stage deploy \
  --branch BC-56-kings-corner-hand-fan --worktree C:/Users/famla/Documents/Git/bonkey-apps/wt-bc56 \
  --since-sha <stage-2 head SHA>
```

| Exit | Meaning                                                                    | What to do                                                  |
| ---- | -------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `0`  | the stage delivered                                                        | advance it                                                  |
| `1`  | **STALLED** — a check genuinely failed                                     | probe, then recover — after reading the timing rule below   |
| `2`  | usage error                                                                | fix the command                                             |
| `3`  | **INDETERMINATE** — nothing failed, but something could not be evaluated   | supply what the report asks for and re-run. **Never re-dispatch on a 3.** |

`--json` for programmatic use. Record each stage's head SHA as you go — it is
the `--since-sha` the next stage is measured against, and at stage 2 that
comparison is what catches a silent stall.

### A false stall is worse than no check at all

**A check that could not run is not a check that failed.** Exit `3` exists
because collapsing "unknown" into "fail" makes a caller re-dispatch an agent
that is *alive*, and the duplicate then competes with the original for the same
machine.

That is not hypothetical. On **2026-08-06**, on this very issue: an artifact
check found no branch and no report, the caller concluded a stall and
re-dispatched — and the duplicate agent's test suites saturated the shared host
(load ~16 on 4 cores), starving the CI the work needed in order to merge. The
check was wrong, and acting on it cost more than not checking would have.

Exit `3` is a question, not a verdict. Its commonest cause is a deleted branch
with no `--since-sha` — which is exactly what a **successful** stage 3 looks
like, since auto-merge deletes the head ref.

### An artifact check is only conclusive AFTER the liveness budget

Early in a stage, "no branch on the remote" is **indistinguishable** from "the
agent has not pushed yet". The script cannot separate those and does not try —
**the liveness budget below is what separates them**, and the script's own
STALLED output says so.

Do not act on an exit `1` before the budget has elapsed. That is precisely the
2026-08-06 mistake: the re-dispatch happened well inside the budget, because the
artifact check on its own looked conclusive.

Three more things worth knowing about its edges:

- **Stage 3 is not required to move the head.** Its artifact is the PR; a PR
  that goes green first try correctly leaves the head where stage 2 put it. Only
  stage 2 is measured on a new SHA.
- **It proves a PR was _opened_, not that it is open now** — the
  `refs/pull/<n>/head` refs persist for closed and merged PRs (which is also how
  it recognizes a merged, branch-deleted PR rather than calling it "nothing was
  delivered"). Confirm the state with `mcp__github__pull_request_read` before
  calling a deploy stage finished.
- **Always pass `--worktree`.** Without it the uncommitted-work check does not
  run, and the summary says `OK (PARTIAL)` rather than `OK` precisely so a
  skipped check never reads as a delivery.

It never inspects the tracker, because the tracker is not evidence.

Also check the repo's **shared primary checkout** is clean
(`git -C <primary-checkout> status --porcelain`). Output there means an agent
wrote where it shouldn't have — a stage failure regardless of the diff's
quality. Move that work onto the right branch from inside a proper worktree
before anything else; never commit it where it sits.

## Poll on a liveness budget

Do **not** treat "no notification yet" as "still working". After dispatching,
re-run the check above on a timer.

Observed healthy stage durations are roughly **25–50 minutes**. An agent past
about **2× the healthy duration for its stage — call it 90 minutes — with no
change in the artifact state is presumed stalled**, and gets probed rather than
waited on. Adjust the budget for an unusually large story, but adjust it up
front and say so; "it's probably still going" after the budget has passed is the
reasoning that cost twelve hours on BC-28.

## Queued checks are not a dead runner

Related failure of the same kind — concluding from an absence. **A saturated
shared host looks identical to a runner outage**: in both cases jobs sit
`queued` and nothing progresses. "No runner / runners offline" was
independently and *wrongly* concluded by three separate agents on 2026-08-06,
when the real cause was a duplicate agent (see above) running test suites that
pinned the box.

**The distinguishing evidence is whether any job on any PR has completed
recently.** If one has, the runners are alive and the queue is contended — wait,
don't diagnose. That check costs one API call and would have prevented all three
wrong diagnoses.

The consequences of getting it wrong are real: re-triggering or re-running
workflows to "fix" a phantom outage is what **evicts queued runs** (see
`.claude/rules/ci-release.md`), turning a slow queue into a lost one. And note
that a stalled agent's own runaway processes can be the thing saturating the
host — so an apparent CI outage can be a symptom of the very problem this rule
is about.

`enable_pr_auto_merge` reporting `unstable status` while checks are queued is
this same situation, and is **not terminal** — retry once the queue drains.

## Probe before recovering

`SendMessage` to the agent is cheap and gives a reliable answer.
`had no active task; resumed from transcript in the background` means it has
been dead, not busy. A live agent answers about its work.

### Count its background tasks — a stalled agent is not necessarily still

**AMENDED 2026-09-15 (BI-61, filed by Cards).** "Resumable, not lost" below
assumes a stalled agent *stays put*. It does not, if it left background shell
commands running. Every background command that exits sends a task
notification, that notification **re-wakes the agent**, and the agent typically
starts another background command and stalls again.

**BC-204, 2026-09-10.** A worker stalled on a backgrounded test loop.
`SendMessage` was unavailable in that session, so the manager dispatched a
finisher into the same clone. The original then re-woke **three times** — as its
tests, then typecheck, then lint finished — starting a new background command
each time. For that stretch **two live agents shared one worktree**: the
2026-08-06 duplicate-agent failure, reached from the opposite direction. Nothing
diverged, but only because the original's commands happened to be read-only.

So, before concluding an agent is inert:

* **An agent that ended its turn on "I'll resume when the background X
  finishes" is not dead.** It is scheduled. Count its background tasks before
  assuming nobody else will touch that worktree.
* This is one more reason **gates must never be backgrounded** (see *Gates run
  synchronously, in the foreground*). A backgrounded gate does not merely stall
  the turn — it leaves a re-wake trigger behind it.

## Recover with this message, not an improvised one

A stalled agent is **resumable, not lost** — its context and its worktree are
intact, and 25+ minutes of work went into them. Do not re-dispatch from scratch
and do not discard the worktree. `SendMessage` the same agent with the
finish-the-job instruction, filled in with what you actually observed. This
recovered every stalled agent it was tried on:

> You have unfinished work: `<what is uncommitted / unpushed / not opened —
> name it concretely>`. Finish it now, in this turn, yourself.
>
> Run any remaining gates **synchronously in the foreground** and read the
> output — do not background anything, and do not end your turn waiting on a
> monitor, a notification or a background task; nothing will wake you.
> Then `git add` everything including untracked files (`git status --porcelain`
> must end empty), commit, and `git push -u origin <branch>`.
> `<For a PR stage:>` Then open the PR against `main` — a restriction you were
> given about the PR (draft, no auto-merge) is not permission to skip opening
> it. Then, and only then, transition the tracker.
>
> Report the branch, the head SHA, and the PR number. Do not report success for
> anything you have not verified exists.

**When `SendMessage` is unavailable and recovery means a NEW agent in the same
clone, `TaskStop` the original first. This is mandatory, not a precaution.**
The order matters, because stopping first without looking discards state:

1. Read the clone's state — `git status --porcelain`,
   `git log origin/main..HEAD`, `git ls-remote`.
2. `TaskStop` the original.
3. Only then dispatch the finisher.

Two agents in one worktree is the failure this rule already names; a re-wake
reaches it without anyone dispatching twice on purpose.

Re-run the mechanical check afterwards. Only if the resume also fails do you
escalate: a comment naming the exact state the branch and worktree are in,
transition back to **To Do**, and raise it in the run summary.

## An unattended run never ends quietly mid-flight

A run finishes in one of two ways: every issue reached its terminal state, or
the summary **names the specific stage that stalled**, on which issue, and where
its work is sitting. "No news" is not an outcome — it is the bug this rule
exists to prevent.

## AMENDED 2026-08-18 — liveness is measured in artifact change, not minutes

The 90-minute budget above is a backstop for a **frozen** artifact, not a
deadline. Judge an agent by whether its artifact state **moved** since the last
check:

| Observation between two checks | Reading |
| --- | --- |
| untracked files appeared, then became staged, then committed | alive, advancing |
| a new SHA on the remote | alive, delivered a stage |
| byte-identical working set, nothing pushed, budget elapsed | presumed stalled — resume it |

On 2026-08-17 a worker ran ~100 minutes on one story while visibly progressing
at every check (throwaway probe specs consolidated into one committed guard,
then staged, then pushed). Resuming it on the clock alone would have duplicated
an hour of work and put two agents on the same worktree — the 2026-08-06 failure
this file already warns about, arrived at from the opposite direction.

Cheap check, and it costs nothing to repeat:

```sh
git -C <worktree> status --porcelain     # has the working set moved?
git ls-remote --heads origin '<BC-nnn>*' # has a SHA appeared or changed?
```

**A dead agent is not the same as lost work.** Two workers died mid-run on
session limits; both had already pushed a branch and opened a PR, so the landing
was finishable without them. Before recovering *anything*, check for the
artifact — you may have nothing to recover.

## Stage 3 is where this rule keeps failing — stop dispatching it

Epic BC-114 dispatched **four** stage-3 agents (BC-119, BC-121, BC-116, plus a
recovery). **All four** opened their PR correctly, then ended the turn with some
variant of *"I've started a background poll and will report once checks settle."*
Every one had to be killed. The prohibition was in their prompts verbatim and in
bold. Restating it did not help.

The pull toward waiting is structural, not careless: stage 3's job genuinely
*is* to see a PR through CI, the agent has nothing useful to do for ten minutes,
and "poll in the background" reads as responsible rather than as the stall it is.

**Squash auto-merge already solves this.** Once armed on a mergeable PR, GitHub
lands it on green with nobody watching. An agent sitting on a monitor adds
nothing but the opportunity to stall.

So the division of labor that worked for BC-117, BC-118, BC-120 and BC-122
after the fourth stall:

- **Agents run stages 1 and 2** — branch, implement, audit, fix, push. None of
  those stalled; this is where subagents are genuinely effective.
- **The caller runs stage 3 inline**: open the PR, arm squash auto-merge,
  register a `Monitor` for the merge commit, and transition the tracker itself
  once that commit exists. Fewer agents, less context burned, no stall — and the
  caller ends up holding the ground truth it was required to verify anyway.

If you do dispatch stage 3, its Definition of Done ends at **"PR open and
auto-merge armed"**, and the prompt must state that reporting *"open, armed,
checks pending"* and **ending the turn** is the correct, complete outcome. The
failure was never that agents stopped — it was that they stopped while claiming
they would continue.

### `git push` can succeed while pushing nothing

On the Windows host a fresh clone has no git identity: `git commit` fails with
`Author identity unknown` and a subsequent `git push` cheerfully publishes a
branch pointing at `main`'s tip, with entirely normal output. `git status
--porcelain` is empty in that state too — it is empty both when everything is
committed and when nothing was staged.

Pair it with `git log --oneline origin/main..HEAD` and require real commits.
See `.claude/rules/windows-checkout.md`.

## A regression guard that cannot fail is worse than no guard

Two guards shipped in this repo were defective in ways that read as thorough:

- **#1245** — a sweep asserting a row's geometry, run through a helper that
  submitted the bid first, so the row under test had already unmounted. It could
  not fail on a revert. Fixed in #1246.
- **BC-128's first guard** — pinned the exact settled pixel values. Those are a
  product of host font metrics, so it was over-specified on one machine **and
  passed vacuously on the CI runner**, where the board settles even unfixed.

Both were caught the same way, and it is the standard for any guard you add:

1. **Mutation-verify in both directions.** Revert the fix, confirm the test goes
   RED and that it fails on *its own named assertion*; restore, confirm GREEN.
   **Report both outputs** — "I added a regression test" is not evidence.
2. **Revert the mutation before committing.** `git diff` must carry no trace.
3. **Add an oracle assertion** where the tier allows it — a case asserting the
   *unfixed* behavior still misbehaves, so the suite cannot pass vacuously if
   the mechanism under test is neutered.
4. **Assert the invariant, not an incidental measurement.** "The board comes to
   rest" survives a host with different font metrics; "it comes to rest at
   191 dp" does not. If a literal is environment-derived, sweep a band or derive
   the expectation, and prove the guard still goes red on a revert afterwards —
   a loosened assertion is exactly the change that silently stops guarding.

## Every control gets both axes — not just the guard you wrote

The standard above is for a guard **you are adding**, in the session you add it.
It does not reach the larger population: controls that were inherited, look
correct, and have never once been checked. Five of those were found across two
boards in one pass (BI-38) — a scheduled watcher, a CI gate, a
`continue-on-error` step, a `jq` guard, and an entire E2E workflow with 1432
runs and zero successes. None was doubted, because none had ever gone red.

> **Green history is fully consistent with never having run.**

A control — a test, a CI job, a linter, a scheduled watcher, a guard clause, a
CLI that reports "looks good" — counts as working only once **both** of these
have been observed:

1. **It executes**, on the trigger that actually matters.
2. **It discriminates** — red with the defect present, green without.

Neither implies the other. A control that never runs is merely invisible; a
control that runs on *nothing* is worse, because it emits a green that is
indistinguishable from a real one.

### Axis 1 — did it ever run?

Check the **invoker**, not the repo. The file being correct and committed is a
statement of intent; this file's own mirror rule applies — observe the running
system, not its configuration.

| the control | why it was inert | what shows it |
| --- | --- | --- |
| `Watch-Runner.ps1` (BI-26) | `Register-RunnerWatch.ps1` shipped and was never invoked | `Get-ScheduledTask` **on the host**, not the file in the repo |
| `maestro-e2e.yml` (Tier 4) | 1432 runs, 0 successes ever — the greens are `pull_request` runs where the emulator job is `skipped` | job conclusions, not the run conclusion |
| `test-expo-health` (BP-42) | `continue-on-error` — structurally incapable of failing | read the step's own keys |
| `launch-home.yaml` (BP-67) | two commits in its whole history, both fixes for the same error, neither validated — no host existed to run it on | does **any** run exist at all |

**A run conclusion is a rollup.** A `success` run can contain a skipped gate,
and that is the commonest shape of an inert CI control. Descend to the job:

```sh
gh run view <run-id> --json conclusion,jobs \
  --jq '"RUN: \(.conclusion)", (.jobs[] | "  JOB \(.name): \(.conclusion)")'
```

Real output, `bonkey-cards-app`, 2026-09-09 — the run is green and the gate
never executed:

```
RUN: success
  JOB detect source changes: success
  JOB CI complete: success
  JOB typecheck / lint / format / test: skipped
  JOB workflow lint (zizmor): skipped
```

Descending is necessary and not sufficient, because a **step index** is
positional and shifts whenever a conditional step appears, vanishes or flips:

> **run conclusion → job conclusion → step index → step name. Only the last is
> stable.** Address the thing you mean — a step _name_, a commit _SHA_, an
> explicit stderr channel — never a value that is derived or positional.

Same shape outside CI: `$?` after a pipe is the **last** command's status, so
`somecheck | tail` reports 0 for everything. Two agents hit this on 2026-08-30,
one of them in the reply to the message warning about it.

### Axis 2 — can it fail?

The way to know is to **make it fail on purpose**. There is no other way; a
green tells you nothing about what would have produced a red.

Three controls from 2026-09-09, each of which passed while checking nothing:

| the control | what it printed | what it was actually saying |
| --- | --- | --- |
| `prettier --check` on a path in `.prettierignore` | `All matched files use Prettier code style!`, exit 0 | it checked **zero files** — byte-identical bad content exits 1 when the path is not ignored |
| `rtk discover` | `No missed savings found. RTK usage looks good!` | it scanned **0 sessions** |
| a four-zone `TZ=<zone>` test matrix | four green legs | most zones silently resolve back to the system zone on this host, so the matrix ran `Chicago, UTC, Chicago, Chicago` — green whether or not the code handles zones. It invalidated a merged story's central evidence |

> **A green over an empty input set is indistinguishable from a green over a
> conforming one.** Both print success in the same words.

The whole method, in the pair that separates them — verified, not proposed:

```sh
printf 'const x    =     1\n' > ignored/bad.js   # path matched by .prettierignore
npx prettier --check 'ignored/**'
#   -> Checking formatting...
#      All matched files use Prettier code style!          exit 0

printf 'const y    =     2\n' > watched.js       # same defect, not ignored
npx prettier --check watched.js
#   -> Code style issues found in the above file.          exit 1
```

So prove axis 2 with **three** cases, not one:

- the **known real defect** — must fail
- a **known-good input** — must pass, or the control is merely always-red
- a **deliberately broken synthetic input** — must fail, or the control's
  *scope* misses the defect class even though its logic is sound

The third is the one people skip and the one that pays. Designing a Maestro
parse gate: `maestro check-syntax` exits 1 on the real defect, which looked
sufficient. It does **not follow subflow references** — a gate sweeping the
obvious `flows/*.yaml` exits 0 while all 14 flows are unparseable. It would have
shipped green as the fix for the problem it cannot detect.

### Report the red, not the control

"I added a guard", "the gate is in place" and "CI is green" are all axis-free.
When you claim a control works, name what you did to make it fail and paste
what came back. A control whose red nobody has ever seen is a message, not a
control.

### Deliberate inertness is not this failure

`native-impact-gate.yml` is a required check that always passes, and it is **not**
an instance: it was neutralized at owner request on 2026-08-05, the file says so,
and it carries revert instructions. A signposted, reversible decision is a
decision. **The failure is the undocumented one — where nobody knows the control
is inert.** If you deliberately neuter a control, say so in the file and say how
to undo it; a rule that pathologizes deliberate choices gets ignored, which
costs more than the choices do.

## An unobserved thing is not an absent thing — and a defined thing is not a running thing

Eight instances in roughly 24 hours across four sessions (2026-08-26/27). One
shape, two directions. It is the most common way we reach a confident wrong
conclusion, and every instance below was reported to someone as fact.

### Direction 1 — empty output read as absence

**A check that produced nothing is not a check that proved nothing is there.** A
tool that elides, a query that failed, a process that is merely quiet, and a
genuine absence are indistinguishable from empty output alone.

| observed | read as | actually was |
| --- | --- | --- |
| `git ls-files` returned 24 of 30 paths | a dropped-row listing | **a correct listing of a stale tree** — see below |
| a `grep` for a known sentence found nothing | the file does not contain it | the sentence **wrapped across two lines**; single-line `grep` cannot match it |
| a long `grep` produced no output in-band | no matches | it exceeded the timeout, moved to the background, and returned **7 matches** elsewhere |
| `find` showed no `rules/`; `git show` gave `fatal: Not a valid object name` | the files were never moved | querying `origin/main` in a repo whose default branch is `master` |
| a suite emitted nothing for minutes | a stalled process | a 24-minute run, progressing |
| `gh api .../actions/runners` returned no output | zero runners online | a runner that was **busy** |
| `docker inspect .State.OOMKilled` = `false` | no OOM kill | a cgroup OOM that killed a **child**; the flag only reports the main process |
| `gh variable list` showed no `CI_RUNNER` | that repo does not use the fleet | an unset variable whose workflow **default is self-hosted** |

### Direction 2 — a definition read as a deployment

| observed | read as | actually was |
| --- | --- | --- |
| three `runner` services in `docker-compose.yml` | three runners running | **one**; the other two sit behind compose profiles, off by default |
| `RestartCount=6` | six failures | six **completed jobs** — the runner is ephemeral and exits cleanly each time |

### The rule

> **Absence claims need a second, differently-shaped check. Presence claims do
> not.**

An eliding tool, a failed query and a quiet process can only ever manufacture
false **absence** — none of them can invent a row that was not there. So "X is
missing", "nothing is running", "it is not configured" and "it has stalled" all
rest on the one thing a broken observation can fake. "X is present" does not.

This tells you *when* to spend the second check, which is why it is affordable.
"Verify everything" is both wrong and unaffordable.

And its mirror: **observe the running system, not its configuration.** A service
definition, a declared environment, a referenced variable and a written policy
are all statements of intent. `docker compose ps`, not the compose file.

### The cheap second checks

| the claim | what separates it from the artifact |
| --- | --- |
| "no runner / the fleet is down" | has **any** job completed recently? If yes it is contended, not dead |
| "the file is not tracked" | `git ls-files --error-unmatch <path>` |
| "it is not at that ref" | check the ref name first — `master` vs `main` |
| "the process stalled" | has its **artifact** moved? (see the 2026-08-18 amendment above) |
| "it was not OOM-killed" | the kernel log. `docker inspect` under-reports |
| "N replicas are running" | `docker compose ps` |
| "that variable is unset, so the feature is off" | read the **default** at the use site |
| "the file does not contain that phrase" | `tr '\n' ' ' < file \| grep -o "phrase"` — prose wraps |
| "the grep found nothing" | did it **complete**? A backgrounded command returns nothing in-band |
| "the file is not in the repo" | `git rev-parse --short HEAD` — **which tree are you reading?** |

Every one of these is a single command. Each of the failures above cost more
than the check would have.

### Before you conclude a file is missing, say which tree you are in

The first row of that table was investigated as a truncation bug for two weeks.
It was not truncation. **It was a correct listing of a checkout that was stale
by fourteen hours.** Every number reproduces exactly by commit: the older tree
holds exactly 24 files and zero `rules/`, the newer holds exactly 30, and the
set difference is precisely the six paths reported missing.

The discriminator is cheap and general, and it settles this class without any
tooling test:

> **Truncation removes one contiguous run from an end. A wrong-tree answer
> removes a set that is contiguous in some *other* ordering** — history, usually.

The six "missing" files sat at position 11 and positions 24–26 and 28–29 in
alphabetical order, with a surviving file at position 27 between them. **No
byte-stream cut can do that.** A commit delta does it every time.

So before reporting an absence:

```sh
git rev-parse --short HEAD && git status -sb | head -1
```

This is not hypothetical bookkeeping. This repo routinely has six live worktrees
at different commits, `cd` does not persist between tool calls, and a local
`master` left unfetched goes stale within a day. The session that *diagnosed*
this then reported a rule file "does not exist on `master`" — reading a local
`master` fourteen commits behind. The finding did not protect its own finder.

### Worked example: the corruption that only sometimes announces itself

Two sessions wrote the same regex — `jest-util`'s `replacePathSepForGlob` — into
a document on this host. The shell silently collapsed a doubled backslash in
both, through a **quoted** heredoc and through `printf '%s'`, neither of which
should transform anything and neither of which errored.

One collapse produced an invalid regex and threw immediately. The other produced
a regex that still parsed, with different behavior, and was caught only by
diffing against the installed library.

**Whether this class of corruption is loud or silent is luck** — it depends
entirely on what the damage happens to leave behind. So "it ran, therefore the
text arrived intact" is not an inference available here.

Do not write backslash-bearing content through the shell on this host: build the
string via `chr(92)`, or use a file-writing tool. Then verify against the
**upstream source**, not against your own intent — confirming that a regex
"looks right" is checking your memory, not the file.

### Direction 3 — verifying the wrong noun

The eight rows above all turn on a signal that was absent, elided or
misinterpreted. This one has **no absent signal at all**. Everything observed
was present and truthful.

A commit was pushed to a branch whose PR had already merged and closed. Two
statements, both true:

- "the push succeeded"
- "the PR shows my commit"

Both are properties of the **branch**. The claim being made was about `master`.
The content never landed, and three separate reports said it had.

> **"Pushed" and "the PR shows it" describe the branch. The artifact is the
> content on the target.** Verify the noun the claim is about.

The check costs nothing and names every ref that actually carries the commit:

```sh
git branch -r --contains <sha>          # which refs really have it?
git log --oneline origin/master ^<sha>  # or: is it reachable from the target?
```

A merged PR is **not** evidence that a later commit landed. Auto-merge deletes
the head branch, so a subsequent push silently **recreates** it — attached to
nothing, looking entirely normal.

The session that hit this had caught the identical shape hours earlier on
another repo, flagged it as debris, and then repeated it. Having the precedent
in hand did not help, because the failure is not a knowledge gap: at the moment
of checking, a true fact about the branch is genuinely reassuring.

## Before you write the cause down, run the control

The cheapest habit in this file, and the one that most often separates a good
story from a true one.

A jest pool was raised from a hardcoded `2` to a derived `3`. CI went red —
**3655 tests passing, runner exiting 1** on a teardown warning. The obvious
reading was that the extra worker caused the leak. It fit the evidence, it
would have made a clean commit message, and it was false: a two-minute control
run at the old concurrency reproduced the leak, proving it pre-existing.

Had the story shipped, the rule derived from it would have been confidently
wrong, and `2` would have been recorded as a fix for something it never fixed.

> **A causal claim is an assertion about a counterfactual.** "X caused Y"
> requires observing Y *without* X. Run it before you write it down.

This is the same standard as mutation-verifying a guard: an explanation you
have not tried to falsify is a hypothesis wearing a conclusion's clothes.

## A verification that shares machinery with what it verifies is not a verification

Two instances on 2026-08-27, both found only because something later took a
different path and disagreed.

**Twelve files were corrupted with double-encoded UTF-8** — `subprocess` with
`text=True` decodes as cp1252 on Windows. The check that should have caught it
compared the written file against the expected content, and **both sides went
through the same broken decode**, so they matched. The comparison was real, the
machinery was shared, and the bug passed straight through it.

**A green CI run was cited as proof that `main` was clean.** The run existed and
was green. It was a `pull_request` run on the branch head, and `ci.yml` is
`pull_request`-only by owner decision, so a merge to `main` runs nothing at all
— there was never going to be a run for the commit in question. Absence of a run
read as presence of a passing one, via a run that was about something else.

> **If the check and the thing being checked go through the same code path,
> the check can only confirm that the path is self-consistent.**

This is the general form of two rules already in this file — the control run,
and mutation-verifying a guard. It extends them past tests to *any* verification,
including the ad-hoc ones you write while confirming a fix.

### What makes a second check independent

Not "run it again". Not "check more carefully". The second check has to differ
in a way that could not share the fault:

| shares machinery | independent |
| --- | --- |
| re-read the file the same way you wrote it | read the bytes; compare hashes |
| diff two strings both produced by the same decoder | compare byte length, or decode via a different path |
| "the latest run is green" | name the **ref** the run was about, and check it matches |
| re-run the failing command | run the *counterfactual* — the old value, the reverted fix |
| grep for the token | read the config, or exercise the behavior |

The cheapest reliable version is usually **a different tool, not a second
attempt**.

### And say which ref your evidence is about

A CI run is evidence about **one commit**. `gh run list` sorted by time answers
"what ran most recently", never "did the thing I care about pass". Both facts
can be true and unrelated.

```sh
# Address the workflow by FILENAME. Display names drift, filenames do not —
# `-w CI` fails outright: "could not find any workflows named CI".
gh run list -w ci-monorepo.yml -L 2 --json headBranch,headSha,event,conclusion

# Better: address the COMMIT and drop the workflow name entirely. Derive the
# trunk — it is `master` in bonkey-org and `main` in the product repos.
TRUNK=$(git symbolic-ref --short refs/remotes/origin/HEAD)
gh api "repos/<owner>/<repo>/commits/$(git rev-parse "$TRUNK")/check-runs" \
  --jq '.check_runs[] | "\(.name): \(.conclusion)"'
```

The second matches this section's own argument: a run is evidence about **one
commit**, and it removes a derived identifier rather than descending through it.
**Caveat, from running it:** unfiltered it returns every check on that SHA,
including unrelated scheduled ones — `Delete artifacts older than N days` came
back alongside `build` and `deploy`. Filter to the checks you actually mean.

If the workflow does not trigger on the event you are asking about, **no run
exists and none was coming**. That is not a green result; it is no result.

This command block was itself broken for months, three lines above the sentence
it illustrates, in the copy every manager restages from. It was found by
applying the axis-2 habit to a rules file: **run the commands you quote.**
