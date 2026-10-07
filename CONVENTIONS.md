# Conventions

[CONTRIBUTING.md](CONTRIBUTING.md) states contribution policies, and [PRINCIPLES.md](PRINCIPLES.md) explains their purpose. This reference settles routine choices and gives formats and commands for applying those policies. Requirements and recommendations follow the distinction in CONTRIBUTING.md.

## Across media

As general writing guidance, write for readers who do not share your context. Prefer precise terms and explicit actors. Keep one main idea per unit and introduce information in an order readers can follow. Explain what the surrounding artifact cannot readily show.

<a id="c01"></a>

**[C01](#c01). Prose clarity**

Apply these conventions to prose sentences.

- <a id="c01-a"></a>**[C01.a](#c01-a). Order information from familiar context to new information.** Readers should be able to follow the sentence from left to right.

- <a id="c01-b"></a>**[C01.b](#c01-b). Keep subjects close to their verbs.**

- <a id="c01-c"></a>**[C01.c](#c01-c). Use pronouns only when their referents are clear.** Repeat a name when a pronoun could refer to more than one entity.

- <a id="c01-d"></a>**[C01.d](#c01-d). Replace semicolons, colons, and em dashes with clearer punctuation or separate sentences.** Use periods, commas, or parentheses according to the relationship being expressed. Preserve punctuation required by code, URLs, message syntax, source references, and exact quotations.

## Code

### Names and boundaries

<a id="c02"></a>

**[C02](#c02). Names and types**

- <a id="c02-a"></a>**[C02.a](#c02-a). Name modules for the responsibilities they own.**

- <a id="c02-b"></a>**[C02.b](#c02-b). Name functions for the operations they perform.**

- <a id="c02-c"></a>**[C02.c](#c02-c). Name parameters for what callers supply.**

- <a id="c02-d"></a>**[C02.d](#c02-d). Name local values for their roles in the computation.**

- <a id="c02-e"></a>**[C02.e](#c02-e). Use types to express constraints they can enforce.**

- <a id="c02-f"></a>**[C02.f](#c02-f). Name recursive helpers for what they compute or traverse.** Do not use generic names such as `aux`, `go`, or `loop` as defaults.

Check existing uses of a concept before choosing its name. Names are part of the specification vocabulary, so misleading names can obscure semantic errors.

Rename a component once its boundary and responsibility support the new name. Public APIs should express the intended semantic model even when dependency constraints require different internal module paths. Prefer explicit organization over broad buckets such as `core` when distinct responsibilities can be named.

### OCaml

<a id="c03"></a>

**[C03](#c03). OCaml conventions**

- <a id="c03-a"></a>**[C03.a](#c03-a). Follow OCaml's casing conventions.** Use `snake_case` for values and types and `PascalCase` for modules and constructors.

- <a id="c03-b"></a>**[C03.b](#c03-b). Reserve `with_*` for wrappers that run a callback between setup and teardown.**

- <a id="c03-c"></a>**[C03.c](#c03-c). Prefer readable recursion or folds over mutable references when they make control flow clearer.**

- <a id="c03-d"></a>**[C03.d](#c03-d). Prefer accumulator-first parameter order for accumulator updates.** Follow `fold_left`.

- <a id="c03-e"></a>**[C03.e](#c03-e). Use `@@` only when it clearly reduces indentation around a single callback body.**

Prefer direct code when handling exceptions.

<a id="c05"></a>

**[C05](#c05). Compiler directory layout**

- <a id="c05-a"></a>**[C05.a](#c05-a). Keep reusable code in `lib/`.** In compiler components, `spectec/lib/` includes domain presentation, CLI infrastructure, and error rendering.

- <a id="c05-b"></a>**[C05.b](#c05-b). Keep CLI infrastructure in `lib/cli/`.** Targets can use it and register their CLI modules.

- <a id="c05-c"></a>**[C05.c](#c05-c). Keep entrypoints in `bin/`.** Compiler entrypoints in `spectec/bin/` load plugins and dispatch commands.

## Comments

Before adding a comment, consider whether a clearer name, smaller function, or stronger type can express the information. Omit comments that only paraphrase code, repeat a name, or label the next block.

A reader should be able to understand a comment without seeing an earlier version of the code.

<a id="c07"></a>

**[C07](#c07). Comment placement and idiom**

- <a id="c07-a"></a>**[C07.a](#c07-a). Use function definition comments for caller-visible facts not evident from the signature.** For example, explain a required input order here.

- <a id="c07-b"></a>**[C07.b](#c07-b). Use function body comments for non-obvious constraints or choices.** These can explain invariants, external constraints, specification rules, or implementation choices.

- <a id="c07-c"></a>**[C07.c](#c07-c). Match the surrounding code's comment style.**

## Documentation

Document the current system's organization, use, and lasting constraints. Put setup and usage guidance in the relevant README, and keep component-specific details near the component. Link to authoritative explanations when repeating them would create competing versions.

## Build and checks

<a id="c09"></a>**[C09](#c09). List formatter versions and relevant formatting, checking, testing, and expectation-update commands by repository and component.**

Run commands from the repository root after following the [README setup instructions](README.md#installation). The [Makefile](Makefile) defines the available targets. It selects an opam switch through `SWITCH`, which can be overridden for the environment being used.

| Command | Purpose |
| --- | --- |
| `make fmt` | Format OCaml with ocamlformat 0.27.0, pinned in [spectec/.ocamlformat](spectec/.ocamlformat). Run before committing OCaml changes. |
| `make fmt-check` | Check OCaml formatting without applying edits. |
| `make check` | Type-check libraries and executables without building the final executable. |
| `make exe` | Build the executable with the release profile. |
| `make test-quick` | Run the fast test groups, including package ownership and plugin discovery. |
| `make test` | Run the broader compiler and interpreter tests. |
| `make promote` | Accept generated test expectations after running the affected tests and reviewing their output. |

Install the formatter with `opam install ocamlformat.0.27.0` in the selected switch if needed. Override `SWITCH` when the local switch has a different name from the Makefile default. Check the Makefile for narrower test targets when a change affects only one component.

The converter checks use `remerkleable` and exercise conversion with local fixture types.

```bash
python3 Converter/SSZToJson/test_ssz_to_json.py
python3 Converter/JsonToSSZ/test_json_to_ssz.py
```

They do not exercise the external Ethereum clients. Use the [differential-testing instructions](README.md#6-diff_testingpy) and [converter documentation](Converter/README.md) for integration checks. Editor-specific setup and checks belong in the [editor documentation](editors/README.md).

When `.expected` files conflict, resolve the source changes first, run the affected tests to produce current output, then promote and inspect the expectations. `make promote` accepts available output. It does not run the tests that generate it. Rerun the affected tests after promotion.

## Change records

### Commit messages

<a id="c10"></a>

**[C10](#c10). Commit classification and format**

<a id="c10-a"></a>**[C10.a](#c10-a). Use `type(scope): summary`, with standard types and the additional `reorg` type.**

Use this format.

```text
type(scope): imperative summary

Motivation describing the prior problem or limitation.

Solution describing the resulting change.
```

<a id="c10-b"></a>**[C10.b](#c10-b). Choose the type by intent and the scope by affected area, regardless of implementation language.**

Standard types include `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, and `style`. Classification applies across implementation languages. The additional `reorg` type covers directory renames, file moves, and layout changes that preserve code structure and behavior. Mechanical caller updates can remain `reorg`. Use `refactor` when responsibilities or APIs change, and `chore` for build configuration or dependencies. A `reorg` label does not establish behavior preservation by itself.

Choose the narrowest accurate scope, such as `converter`, `cli`, `elaborate`, `il`, `interp`, `instrumentation`, or `targets/p4`.

<a id="c10-c"></a>**[C10.c](#c10-c). Use `spec` or `spec/<target>` scopes for specification work, such as `fix(spec/deneb): correct blob validation`.**

The `spec` commit type is deprecated. Historical `spec` commits denote specification changes. Do not rewrite existing history solely to replace the deprecated type.

<a id="c10-d"></a>**[C10.d](#c10-d). List renamed or moved paths in a `reorg` message as `old -> new` bullets and describe mechanical reference updates.** PR scope lists use the same path format.

<a id="c11"></a>

**[C11](#c11). Commit prose**

<a id="c11-a"></a>**[C11.a](#c11-a). Use imperative subjects.** Name the concept. Put code identifiers in the body, where there is room to explain them. For example, `refactor(cli): group shared flags by role` gives the reader a concept, while its body can identify the modules and flag groups.

<a id="c11-b"></a>**[C11.b](#c11-b). Organize bodies as Motivation followed by Solution, without requiring section headings.** The body explains why and what.

<a id="c11-c"></a>**[C11.c](#c11-c). Describe prior problems in past tense by default.** A `Currently, ...` framing is also acceptable.

<a id="c11-d"></a>**[C11.d](#c11-d). Describe solutions in third-person present.** Use forms such as `Adds...`, `Replaces...`, or `The helper is extracted...`. Avoid first-person and future-tense accounts of the solution. These forms also apply to bullets.

<a id="c11-e"></a>**[C11.e](#c11-e). Use prose for one scope and bullets when distinct scopes do not read naturally as a paragraph.** Name concrete identifiers where they help explain the result. A subject can stand alone when it already makes the motivation and result evident.

<a id="c12"></a>

**[C12](#c12). Commit character set and wrapping**

<a id="c12-a"></a>**[C12.a](#c12-a). Prefer ASCII in commit-message prose for predictable terminal display.** Use UTF-8 when accurate names, identifiers, or exact source text require it.

<a id="c12-b"></a>**[C12.b](#c12-b). Treat 72 columns as a wrapping target, not an absolute limit.** Allow long URLs and identifiers to remain intact. PR bodies use Markdown and may use typography appropriate to that medium.

### Sources and credit

<a id="c13"></a>

**[C13](#c13). Source and context trailers**

<a id="c13-a"></a>**[C13.a](#c13-a). Use full URLs with `Original-commit:`, `Copied-from:`, and `Cherry-picked-from:`.** References remain useful outside GitHub's PR view.

<a id="c13-b"></a>**[C13.b](#c13-b). Choose the origin trailer by the source relationship.**

| Trailer | Use |
| --- | --- |
| `Original-commit:` | A change based on an upstream or sibling-repository commit, whether directly ported or adapted. |
| `Copied-from:` | A literal tree import, such as copying a specification directory. |
| `Cherry-picked-from:` | A same-repository cherry-pick from another branch. |

<a id="c13-c"></a>**[C13.c](#c13-c). Use `Reference:` for comparison ranges and other contextual links.** Use a full URL. For merge-based synchronization, retained upstream commits already record their origins and need no duplicate trailers. Local commits adapting upstream work still use `Original-commit:`. Origin and context trailers may coexist with a regression-source record.

<a id="c14"></a>**[C14](#c14). Use `Fixes: <12-character SHA> ("<subject>")` for a known regression's introducing commit.** Preserve its full subject. This format is the exception to the full-URL source-trailer convention. Do not invent an introducing commit when the source cannot be identified.

For a port, place `Ported from <project>.` in its own paragraph between the solution and the trailers. Name the actual source project. Describe meaningful adaptations in the body. Repeat source trailers when a local commit combines several source commits.

```text
Ported from P4-SpecTec.

Original-commit: https://github.com/kaist-plrg/p4-spectec/commit/<sha>
```

In PR bodies and merge summaries, GitHub shorthand such as `org/repo@sha` or `org/repo#number` is appropriate. Preserve author information during a rewrite, while allowing Git to record who created the rewritten commit as its committer. Add coauthor credit for actual joint authorship.

### PR titles and descriptions

Choose a title that identifies the main concept. When several changes form one idea, name that idea. Account for accompanying work in the body under [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations). Concrete titles are easier to understand than abstract labels whose meaning depends on the body.

<a id="c16"></a>**[C16](#c16). Match the PR title form to its category.**

| Type | Title form |
| --- | --- |
| Refactor | `Refactor <concept>` |
| Feature | A concept-led title without a fixed prefix |
| Port | A concept-led title without a fixed prefix |
| Sync | `Sync <area>` |
| Reorg | `Reorg <concept>` |

<a id="c17"></a>

**[C17](#c17). PR sections**

<a id="c17-a"></a>**[C17.a](#c17-a). Start PR bodies with a Motivation section.** Use `## Motivation` and explain the problem or research goal.

<a id="c17-b"></a>**[C17.b](#c17-b). Use a Core Concepts section when design ideas need a separate explanation.**

<a id="c17-c"></a>**[C17.c](#c17-c). Use a Scope section when affected areas and kinds of change need a separate overview.** Neither separate section is necessary when the short overview already explains the result and scope.

As guidance, Core Concepts lists ideas as bolded bullets and closes with an explanation of how they fit together. Omit that closing explanation if the relationship is already clear. Scope groups changes by affected area and theme. A single scope bullet can summarize several commits.

Use `## Minor Changes` for incidental work outside the main theme and `## Future Work` for relevant deferred work or open design questions. Keep the body prose-first and use bullets for concrete changes and scope boundaries.

<a id="c17-d"></a>**[C17.d](#c17-d). End multi-commit PR bodies with a Commit Log section.** Use `## Commit Log`.

<a id="c19"></a>**[C19](#c19). List final commit subjects verbatim and in order.** Include their `type(scope):` prefixes. Do not add backticks or hyperlinks around them. Preserve any literal characters already in a subject. Keep this list synchronized with the final history.

<a id="c20"></a>

**[C20](#c20). Upstream scope groups**

Ports link the upstream PR in Motivation.

<a id="c20-a"></a>**[C20.a](#c20-a). Use `Ported`, `Adapted`, `Omitted`, and Sync-only `Local Changes` as upstream scope headings.** Use these groups where applicable.

- `Ported`: upstream work taken nearly directly.
- `Adapted`: upstream work adjusted for the local context.
- `Omitted`: upstream work not taken, with the reason. This is especially useful for one-to-one Port tracking.
- `Local Changes`: related local-origin work included in a Sync.

Omit empty groups.

<a id="c20-b"></a>**[C20.b](#c20-b). Use GitHub source references in upstream scope groups.** Identify origins, for example `Original: org/repo@sha`. A Port includes necessary local adaptations, while independent local changes need a separate PR.

Drafting the body in a file preserves its formatting when opening a PR.

```bash
gh pr create --title "Refactor <concept>" --body-file pr-body.md
```

Historical examples of the structure include [a refactor](https://github.com/kaist-plrg/spectecx/pull/34), [a change with two themes](https://github.com/kaist-plrg/spectecx/pull/32), [a port](https://github.com/kaist-plrg/spectecx/pull/30), and [a sync](https://github.com/kaist-plrg/spectecx/pull/35). Apply the current requirements when using an older example.

## Review

<a id="c23"></a>**[C23](#c23). Label required changes, suggestions, and questions consistently.** Use labels such as `Required:`, `Suggestion:`, and `Question:` when the status of a review comment could be unclear. Follow [P.review-blockers](CONTRIBUTING.md#p.review-blockers) when explaining why a change is needed before merging. A label is not needed on every sentence.

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

Publish a rewritten branch within the agreement under [P.reviewer-tasks](CONTRIBUTING.md#p.reviewer-tasks) or the maintainer's editorial permission under [P.editorial-cleanup](CONTRIBUTING.md#p.editorial-cleanup). Use a lease against the remote tip you reviewed so another contributor's intervening push prevents replacement. For an example branch named `topic`, capture the tip before rewriting.

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

### Merge messages

<a id="c24"></a>**[C24](#c24). Use `Merge: <lowercase summary> (#PR)` for merge subjects.**

For a multi-commit PR, use this format.

```text
Merge: <lowercase summary> (#PR)

Framing paragraph describing the merged result.

- refactor(scope): Description.
- fix(scope): Description.
```

The summary mirrors the PR title in lowercase. The body serves readers scanning history for what landed, where it applies, and what remains deferred.

<a id="c25"></a>

**[C25](#c25). Merge-message summaries**

<a id="c25-a"></a>**[C25.a](#c25-a). Summarize merged work with thematic `type(scope): Description.` bullets.** Group scoped bullets by theme rather than reproducing the Commit Log. Capitalize each description and end it with a period.

<a id="c25-b"></a>**[C25.b](#c25-b). Group merge-summary bullets under peer sections when grouping improves readability.** One thematic list needs no heading. Peer sections can include `Ported:`, `Adapted:`, `Omitted:`, and `Local Changes:`. Keep the bullets within them in the same scoped form. Source references may use an `Original: <ref>` suffix.

<a id="c26"></a>

**[C26](#c26). Minor and deferred work in merge messages**

<a id="c26-a"></a>**[C26.a](#c26-a). List minor changes in separate merge-message bullets.** Use their appropriate types and scopes.

<a id="c26-b"></a>**[C26.b](#c26-b). Mark deferred work with `DEFERRED:` in merge-message bullets.** Use no separate deferred-work heading.

```text
- DEFERRED: Add support for the remaining input forms.
```

This makes deferred items searchable with `git log --grep 'DEFERRED:'`.

### Integration commands

These examples use `origin` as the publication remote and `topic` as the reviewed branch. Start with a clean integration checkout and update `main` without creating an incidental merge.

```bash
git fetch origin
git switch main
git merge --ff-only origin/main
```

For a multi-commit PR, prepare the merge before recording its cover letter.

```bash
git merge --no-ff --no-commit topic
```

If this merge reports conflicts, run `git merge --abort`. Resolve the conflicts on the PR branch and make the resolutions available for review under [P.conflict-resolution](CONTRIBUTING.md#p.conflict-resolution). Repeat integration after resolving any review blockers. Follow the existing component checking instructions, then record the merge message and publish.

```bash
git commit
git push origin main
```

<a id="c27"></a>**[C27](#c27). Append `(#PR)` to a single-commit PR's commit subject during authorized final cleanup.**

For a single-commit PR, the commit message is the permanent landing record. Before fast-forward landing, use `git commit --amend` on its branch, preserving the author and the complete message. An amend changes the commit ID. Publish the reviewed result with the lease procedure above.

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

### A small contribution

As a hypothetical example, a parser fix can add a diagnostic for an incomplete field declaration and one negative test demonstrating that failure. Keep both in a single commit.

```text
fix(parser): diagnose incomplete field declarations

An incomplete field declaration reached an internal exception, leaving
the user without a useful location for the error.

Reports a syntax diagnostic at the declaration and adds a negative test
for the missing field type.
```

Its PR can contain a short Motivation explaining the same problem and result. It needs no separate Core Concepts, Scope, or Commit Log. If the maintainer corrects a comment or commit wording within the standing editorial permission, the merge notice can say what was corrected. After final cleanup adds the PR number, this single commit is fast-forwarded and its message carries the landing record.
