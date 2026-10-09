# Contribution workflow

This optional reference gives command recipes for applying the [policy outline](../CONTRIBUTING.md#policy-outline). It adds no contribution requirements. Message formats and routine choices belong in [CONVENTIONS.md](../CONVENTIONS.md). History rewrites and publication require agreement under [P.reviewer-tasks](../CONTRIBUTING.md#p.reviewer-tasks) or permission under [P.final-cleanup](../CONTRIBUTING.md#p.final-cleanup). These recipes do not themselves authorize a rewrite or publication.

## Build and checks

Run commands from the repository root after following the [README setup instructions](../README.md#installation). The [Makefile](../Makefile) defines the available targets. It selects an opam switch through `SWITCH`, which can be overridden for the environment being used.

| Command | Purpose |
| --- | --- |
| `make fmt` | Format OCaml with ocamlformat 0.27.0, pinned in [spectec/.ocamlformat](../spectec/.ocamlformat). Use to format OCaml changes before committing. |
| `make fmt-check` | Check OCaml formatting without applying edits. |
| `make check` | Type-check libraries and executables without building the final executable. |
| `make exe` | Build the executable with the release profile. |
| `make test-quick` | Run the fast test groups, including package ownership and plugin discovery. |
| `make test` | Run the broader compiler and interpreter tests. |
| `make promote` | Accept generated test expectations after running the affected tests and reviewing their output. |

Install the formatter with `opam install ocamlformat.0.27.0` in the selected switch if needed. Override `SWITCH` when the local switch has a different name from the Makefile default. Check the Makefile for narrower test targets when a change affects only one component.

Use component documentation for other tools, including [converter usage](../Converter/README.md) and [editor setup](../editors/README.md). Converter checks and external-client integration have different prerequisites and coverage.

When `.expected` files conflict, resolve the source changes first, run the affected tests to produce current output, then promote and inspect the expectations. `make promote` accepts available output. It does not run the tests that generate it. Rerun the affected tests after promotion.

## Opening a PR

Drafting the body in a file preserves its formatting when opening a PR.

```bash
gh pr create --title "Refactor <concept>" --body-file pr-body.md
```

## Revising reviewed commits

Incremental review commits can be folded once review settles. Use an interactive rebase against the chosen review base, which may be a dependency branch for a stacked PR.

```bash
git rebase -i <review-base>
```

Use `fixup` for a follow-up whose message has no independent information to preserve. Use `squash` when combining commits with source trailers or useful rationale, then retain that information explicitly in the resulting message. Describe the final change after folding.

When per-commit buildability needs checking, an interactive rebase can run a check after each resulting commit.

```bash
git rebase -i --exec 'make exe' <review-base>
```

Use the opam switch available in the chosen environment and substitute a more relevant check when appropriate. A failure stops the rebase so the commit can be repaired or folded. This recipe does not imply that every review update needs a rebase or an expensive rerun.

Publish a rewritten branch within the agreement under [P.reviewer-tasks](../CONTRIBUTING.md#p.reviewer-tasks) or the maintainer's final-cleanup permission under [P.final-cleanup](../CONTRIBUTING.md#p.final-cleanup). Use a lease against the remote tip you reviewed so another contributor's intervening push prevents replacement. For an example branch named `topic`, capture the tip before rewriting.

```bash
git fetch origin
git switch topic
reviewed_tip=$(git rev-parse origin/topic)
```

After reviewing the remote work, completing the authorized rewrite, and coordinating any dependent branches, publish with this command.

```bash
git push --force-with-lease=refs/heads/topic:"$reviewed_tip" origin HEAD:refs/heads/topic
```

If the lease fails, inspect the remote updates before preparing another rewrite.

## Landing

These examples use `origin` as the publication remote and `topic` as the reviewed branch. Start with a clean integration checkout and update `main` without creating an incidental merge.

```bash
git fetch origin
git switch main
git merge --ff-only origin/main
```

### Multi-commit PRs

For a multi-commit PR, prepare the merge before recording its cover letter.

```bash
git merge --no-ff --no-commit topic
```

If this merge reports conflicts, run `git merge --abort`. Resolve the conflicts on the PR branch and make the resolutions available for review under [P.conflict-resolution](../CONTRIBUTING.md#p.conflict-resolution). Repeat integration after resolving any review blockers. Follow the existing component checking instructions, then record the merge message and publish.

```bash
git commit
git push origin main
```

### Single-commit PRs

For a single-commit PR, the commit message is the permanent landing record. Before fast-forward landing, use `git commit --amend` on its branch, preserving the author and the complete message. An amend changes the commit ID. Publish the reviewed result with the [lease procedure](#revising-reviewed-commits).

The proposed branch must be exactly one commit ahead of current `main`, with `main` as an ancestor. Check both conditions from the integration checkout.

```bash
git merge-base --is-ancestor main topic
git rev-list --count main..topic
```

The ancestry check must succeed and the count must be `1`. `--ff-only` checks whether fast-forwarding is possible, not the number of commits. If the ancestry check fails, update the branch through the agreed integration process. Once both conditions hold, land it with these commands.

```bash
git merge --ff-only topic
git push origin main
```

## A small contribution

As a hypothetical example, a parser fix can add a diagnostic for an incomplete field declaration and one negative test demonstrating that failure. Keep both in a single commit.

```text
fix(parser): diagnose incomplete field declarations

An incomplete field declaration reached an internal exception, leaving
the user without a useful location for the error.

Reports a syntax diagnostic at the declaration and adds a negative test
for the missing field type.
```

Its PR can contain a short Motivation explaining the same problem and result. It needs no separate Core Concepts, Scope, or Commit Log. If the maintainer performs cleanup within [P.final-cleanup](../CONTRIBUTING.md#p.final-cleanup), the merge notice can say what was corrected. After final cleanup adds the PR number, this single commit is fast-forwarded and its message carries the landing record.
