<!-- retro.md — the review of one run: what got in the way of THE SYSTEM building. Filled in at the end of the build, right after the MVP-ready message; placed in docs/furca/retro.md of the project repository. Every item becomes an issue in the backlog of the system's own repository (the one it was installed from) — a retro that produced no issues did not happen. -->

# Run retro

<!-- Project name, run date, the outcome in one line: MVP ready / ready with discrepancies / run stopped and why. -->

## How to fill this in

- **About the system, not the product — with one exception, and it comes first.**
  Unfinished parts of the product belong in its `tasks.md` and in the spec review.
  Here goes only what got in the way of the system building: the wording of
  templates, the order of steps, acceptance rules, notifications. The exception is
  the opening section below: **what the product gained this run** is the measure of
  the system, not a report on the product, and without it a retro has no scale to
  judge anything else by.
- **Why the exception exists.** Until 17.09.2026 this template said "about the
  system, not the product" with no exception, and that was the only learning loop
  the system had. Every item it produced was about process, because process was the
  only thing it could see: failures of process are loud (a neighbour's stand torn
  down, a lost file, a run that hung), while "the product did not move" raises no
  event at all. Across a week of two live builds the corpus of rules grew in one
  direction only — the build skill reached 139 mentions of runs and gates against
  37 of the product, tests outgrew product code in both projects — and the owner,
  not the retro, was the one who noticed. A loop that cannot see the outcome
  optimises the ritual.
- **From the facts of the run, not from memory.** Sources: the `progress.md` log
  (where it stalled), `questions.md` (which questions had to be asked),
  `decisions.md` (what was decided without the owner), the commit history, blocks
  sent back for rework.
- **Every item is a draft issue:** what happened / where exactly (step, phase,
  file) / what it cost the run / what is proposed to change. An item you cannot
  turn into an issue is a complaint, not a retro.
- **Wording follows `templates/issue-style.md`.** The item travels into a tracker
  that outsiders read: a neutral run name, no quotes from conversations, no names
  of personal infrastructure, no personal data.
- **An empty section is a fine result, but it is written out** with the word
  "nothing". A section left silently empty reads as forgotten.
- **Honest about yourself.** The place where the dispatcher itself blundered is
  worth more than any remark about a template: nobody else will ever see it.

## What the product gained this run

<!-- Fill this in FIRST, before any section below. One line per capability the user has now and did not have before the run, phrased as a user action ("an auditor finishes a check and gets a PDF"), never as task ids or module names. Sources: the spec's readiness criteria and the smokes actually run, not the task graph — a closed task is not a capability. -->

1. <!-- what the user can do now / how it was shown to be true (smoke, screen, live run) -->

**Runs that produced nothing here:** <!-- how many sessions of this run closed without a single wave deployed, and what each was spent on instead. A run whose entire output is tooling — checks, report formats, journals, gates — says so plainly. This is the first item of the retro, not a footnote: it is the failure mode this section exists to catch, and it is invisible in every other artefact, because each such session looks reasonable on its own. -->

**Cost of the run against what it gained:** <!-- lines of product code vs lines of tests and tooling; commits by type. Both numbers come from `git log --numstat`, not from memory. A run where tests outgrew the product needs an explanation here, and the explanation belongs in the sections below as an item about the system. -->

## Where things got stuck

<!-- Where the run lost time: blocked tasks, waiting for the owner's answer, dead agents, merge conflicts, a broken environment, rate limits. For each — how long it stood and what the root cause was. Example: "block web stood for 40 minutes on Q003, although the question had a reasonable default — the rule for when to decide alone was missing". -->

1. <!-- what got stuck / where / what it cost / what to change -->

## Intake questions that did not work

<!-- Questions from the starting intake that produced a poor result: misunderstood by the owner, answered "I don't know" where a precise answer was needed, skipped by a condition and resurfacing during the build, and questions the intake lacked entirely. Example: "database access marked ✅ with no smoke test — the question does not explicitly ask for a verification command". -->

1. <!-- the question / what went wrong / how to rephrase it or what to add -->

## Where the dispatcher blundered

<!-- Its own mistakes running the build: asked the owner about something a default covered; conversely, decided alone what should have been asked; accepted a block with stale documents; re-read code instead of the state files; lost or duplicated a task; declared something verified that was not. -->

1. <!-- what was done wrong / because of what / what the instruction lacked -->

## Proposals

<!-- What exactly to change in the system: templates, the order of steps, acceptance rules, the notification protocol, tests. One change per item: an issue called "improve everything" never gets done. -->

1. <!-- proposal / which item above it fixes -->

## Where this goes

Every item above becomes a separate issue in the backlog of **the system's own
repository** (the one it was installed from), not in the project's repository: it
is the system being fixed, not the product. Critical things are fixed immediately,
the rest lives in the backlog. Duplicates are not created — if an issue already
exists, the table gets a link to it.

| retro item | issue in the system's backlog |
|---|---|
<!-- | Where things got stuck №1 | <owner>/<system repository>#42 | -->
