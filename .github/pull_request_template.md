<!--
Pick the PR shape (see CONTRIBUTING.md, "Pull Requests") and delete the sections it does not use.

| Type     | Title                  | Sections                                                        |
| -------- | ---------------------- | --------------------------------------------------------------- |
| Refactor | `Refactor <concept>`   | Motivation, Core Concept(s)?, Scope?, Commit Log                |
| Feature  | concept-led, no prefix | Motivation, Core Concept(s), Scope?, Commit Log                 |
| Port     | concept-led, no prefix | Motivation (link upstream PR), Scope (Ported/Adapted/Omitted), Commit Log |
| Sync     | `Sync <area>`          | Motivation, Scope (Ported/Adapted/Local Changes), Commit Log    |
| Reorg    | `Reorg <concept>`      | Motivation, Scope (rename list)?, Commit Log                    |

Title: one concept. If it reads "X and Y", look for one name that covers both.
Body: prose first. Use `org/repo@sha` and `org/repo#NN` shorthand for references.
-->

## Motivation

<!-- The problem, pressure, or design goal. Port: link the upstream PR being tracked. -->

## Core Concept(s)

<!-- Refactor/Feature. Bolded bullets for the ideas, then one paragraph on why they hang together.
Drop this section when the Motivation already names the concept. -->

- **<concept>**: <what it is>

<direction the PR moves the code in>

## Scope

<!-- Group commits thematically, not one bullet per commit.
Refactor/Feature: per-area bullets when prose alone gives no map.
Reorg: list the moves (`old/path` -> `new/path`).
Port/Sync: use the subsections below. Each bullet ends with `Original: kaist-plrg/p4-spectec@<sha>`. -->

### Ported

- <summary>. Original: kaist-plrg/p4-spectec@<sha>

### Adapted

- <summary and what changed locally>. Original: kaist-plrg/p4-spectec@<sha>

### Omitted

<!-- Port only. One-line reason per upstream commit not taken. -->

- <summary>: <reason>. Original: kaist-plrg/p4-spectec@<sha>

### Local Changes

<!-- Sync only. A Port with a local fix splits that fix into a separate PR. -->

- <summary>

## Minor Changes

<!-- Optional. Commits that ship here but do not fit the main story. -->

## Future Work

<!-- Optional. Deferred follow-ups and open design questions. -->

## Commit Log

<!-- Filled by .github/workflows/pr-commit-log.yml on every push. Keep the markers. -->
<!-- commit-log:start -->
<!-- commit-log:end -->

<!--
Before requesting review:
- [ ] `make fmt-check` passes.
- [ ] Every commit builds: `git rebase -i --exec 'make test-quick' main`.
- [ ] `.expected` files regenerated with `make promote`, not hand-merged.
- [ ] Commit messages are ASCII, with motivation (past tense) and solution (present tense).
- [ ] Ports carry `Original-commit:` trailers with full GitHub URLs.
- [ ] Refactors, fixes, and features are in separate commits.
-->
