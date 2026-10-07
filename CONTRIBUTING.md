# Contributing

These policies apply the [principles](PRINCIPLES.md) to contribution decisions. Each policy links to its supporting principles. Policy IDs name topics and stay stable when rules move or their wording changes. `↔` marks a tradeoff. See [CONVENTIONS.md](CONVENTIONS.md) for code and prose conventions, message formats, and command recipes. See [README.md](README.md) for setup and use.

## Working together

<a id="p.rules"></a>

**[P.rules](#p.rules). Follow the rules in this guide and CONVENTIONS.md.**

*[Responsibility][responsibility], [Coordination][coordination]*

Contributors are expected to follow the rules in this guide and CONVENTIONS.md, including the component guides linked from them.

Rules marked as guidance, preferences, or defaults describe the recommended approach and should normally be followed. Contributors who take a different approach must let the reviewer know and explain why. All other rules are requirements. Contributors need to agree on exceptions to requirements with the core maintainer before proceeding. Steps marked optional may be skipped.

Reviewers should refer to these documents or their linked guides when asking contributors to follow a rule. They may also raise concrete problems under [P.review-blockers](#p.review-blockers).

Contributors are welcome to raise issues with this guide or CONVENTIONS.md when they have ideas for improving the contribution process.

<a id="p.responsibility"></a>

**[P.responsibility](#p.responsibility). Take responsibility for the work you submit, regardless of tools or assistance.**

*[Verification][verification], [Responsibility][responsibility]*

Contributors are responsible for the work they submit, and reviewers are responsible for the edits they make. Contributors must understand their changes well enough to explain them and answer review questions. AI tools, code generators, and other assistance do not change these responsibilities or the contribution requirements.

Routine AI-use disclosures are not required. Explain tool use when it is part of the research method or necessary to understand a result or its limits. Contributors remain responsible for submitted work, including work copied or adapted from others.

<a id="p.reviewer-tasks"></a>

**[P.reviewer-tasks](#p.reviewer-tasks). Announce the review tasks you will take on and let the contributor take them instead.**

*[Responsibility][responsibility], [Coordination][coordination]*

Reviewers should tell the contributor which tasks they plan to take on, including edits, commits, pushes, history rewrites, and PR metadata changes. This lets the contributor avoid duplicate work or take on those tasks themselves. Final editorial polish remains the maintainer's responsibility under [P.editorial-cleanup](#p.editorial-cleanup).

Before changing behavior, design, or the contributor's stated reasoning, the reviewer should discuss the change with the contributor. History rewrites and PR metadata edits also need agreement unless they fall within P.editorial-cleanup.

<a id="p.editorial-cleanup"></a>

**[P.editorial-cleanup](#p.editorial-cleanup). The maintainer may polish comments and commit messages during final integration.**

*[Provenance][provenance], [Responsibility][responsibility] ↔ [Coordination][coordination]*

The core maintainer bears most of the lasting cost of unclear documentation. During final integration, the maintainer may make the editorial corrections below without asking for separate approval.

- Correct spelling, grammar, formatting, and wording in existing comments while preserving their facts, constraints, and reasons.
- Correct spelling, grammar, and wording in commit subjects and bodies without changing their meaning or motivation.
- Apply commit-message format and wrapping conventions.
- Format existing source and attribution trailers without changing their facts or credit.
- Add the PR number to a single-commit PR's commit subject.

The maintainer may amend commits, rebase their descendants, and push the rewritten PR branch with `--force-with-lease` to publish these corrections. File edits are limited to comments, and executable code, behavior, commit order, and author attribution must stay unchanged. Before rewriting, the maintainer should coordinate with contributors whose branches depend on the affected commits. When merging the PR, the maintainer should tell the contributor what was edited.

An edit that adds an explanation, corrects a factual claim, changes an assumption, or resolves ambiguous intent needs discussion under [P.reviewer-tasks](#p.reviewer-tasks). Changes to motivation, attribution, or PR metadata also follow P.reviewer-tasks.

## Shaping the work

<a id="p.change-scope"></a>

**[P.change-scope](#p.change-scope). Each commit should express one idea, and each PR should develop one main topic.**

*[Coherence][coherence] ↔ [Proportionality][proportionality]*

Edits that implement, test, or explain the same idea belong together. Unrelated ideas should have separate commits so readers can understand and review each change on its own.

A PR may include commits outside its main topic when a separate PR would add review and landing overhead without enough practical benefit. Those commits should remain distinct, and the PR body should explain why they belong. Ports still follow the narrower boundary in [P.port-scope](#p.port-scope).

While a PR is under review, its planned topic should remain stable. Newly discovered independent work normally belongs in another PR, unless the same grouping exception applies. Once the contribution is ready, [P.follow-ups](#p.follow-ups) explains how to handle follow-up work. Final commit preparation follows [P.commit-buildability](#p.commit-buildability).

<a id="p.port-scope"></a>

**[P.port-scope](#p.port-scope). Limit each Port to one upstream PR and its local adaptations.**

*[Coherence][coherence], [Provenance][provenance]*

A Port follows one upstream PR so reviewers can compare the original work with its local adaptations. It may include the local edits needed to make that work function here. Independent local changes belong in another PR. A Sync can cover broader upstream changes and related local work.

<a id="p.established-forms"></a>

**[P.established-forms](#p.established-forms). Prefer established forms when alternatives offer no clear benefit.**

*[Coherence][coherence], [Proportionality][proportionality]*

Familiar forms let readers focus on meaning and avoid repeated decisions about routine choices. When several forms express the same idea equally clearly, follow the established form in the surrounding code or prose. Use a different form when it makes a specific operation, dependency, or relationship clearer. Project-wide conventions settle choices shared across components and documents. Exceptions to required conventions still follow [P.rules](#p.rules).

<a id="p.abstractions"></a>

**[P.abstractions](#p.abstractions). Give each abstraction a responsibility that current callers need.**

*[Coherence][coherence]*

An abstraction adds a concept readers must learn. Its justification should identify an operation current callers need or logic they need to share. Hypothetical future uses alone do not justify generic options or extension points. This applies [YAGNI](https://martinfowler.com/bliki/Yagni.html) to abstractions.

Names and interfaces should express the abstraction's responsibility. Callers should be able to use its operations without knowing their internal steps. Interfaces should show what callers supply and what they can rely on. Inputs that affect results should be explicit by default.

<a id="p.invariants"></a>

**[P.invariants](#p.invariants). Keep invariant enforcement with the data and operations it governs.**

*[Coherence][coherence], [Verification][verification]*

Callers need to know which guarantees they can rely on. The component that owns a value must establish those guarantees when constructing it and preserve them through every exposed update. Keep shared mutable state with the operations responsible for maintaining its constraints. Identify the state's owner and lifetime.

<a id="p.renames"></a>

**[P.renames](#p.renames). Rename declarations and callers together unless a consumer cannot migrate.**

*[Coherence][coherence] ↔ [Coordination][coordination]*

A rename normally updates the declaration and all its callers in the same change. Keeping a compatibility alias can suggest that the two names mean different things, so aliases should not be retained by default.

A temporary alias is acceptable when an identified consumer cannot migrate in the same change. The contributor should record the migration obstacle and agree with the core maintainer on when the alias will be removed.

<a id="p.comments"></a>

**[P.comments](#p.comments). Use comments for constraints and reasons absent from the code.**

*[Coherence][coherence]*

A comment should explain a constraint or reason that names, types, and implementation do not show. Information already evident from the code does not need another explanation in a comment. What changed and why belongs in the change record.

<a id="p.documentation"></a>

**[P.documentation](#p.documentation). Document the current system and keep change history in change records.**

*[Coherence][coherence]*

Project documentation describes the system's current organization, use, and constraints. Readers should be able to follow it without knowing an earlier implementation. The history of a change belongs in change records, where its motivation and result can be explained together.

Give each explanation an authoritative home. Other documents should link to that explanation instead of maintaining competing copies.

## Presenting the change

<a id="p.change-summaries"></a>

**[P.change-summaries](#p.change-summaries). Commit subjects and PR titles should summarize the conceptual change.**

*[Coherence][coherence]*

A commit subject or PR title should name the action and affected concept so readers can identify the change before opening its details. The commit subject describes that commit's idea, and the PR title names the contribution's main topic. The PR body accounts for accompanying work.

<a id="p.commit-intent"></a>

**[P.commit-intent](#p.commit-intent). Classify each commit by its intent, including specification work.**

*[Coherence][coherence]*

Commit types describe the intent of the work, so specification changes use the same categories as other changes. The message should distinguish changes in modeled behavior from changes in notation or organization. Classify structural or behavioral changes by their own intent, even when they accompany reorganization or formatting. Explain that work separately. Type and scope syntax is described in [CONVENTIONS.md](CONVENTIONS.md#commit-messages).

<a id="p.commit-explanations"></a>

**[P.commit-explanations](#p.commit-explanations). Each final commit message should explain the motivation and resulting change.**

*[Motivation][motivation], [Coherence][coherence]*

A commit message should let readers understand why the change was needed and what it accomplishes without having seen the original discussion. Motivation explains the prior problem, limitation, or research goal. Solution describes the resulting change that addresses it. For a refactor, the explanation must identify the structural limitation and show why the new structure addresses it.

When the subject already conveys the required explanation, the message does not need a body. Source records still follow [P.source-credit](#p.source-credit) and [P.regression-origin](#p.regression-origin).

<a id="p.pr-explanations"></a>

**[P.pr-explanations](#p.pr-explanations). Each PR body should explain its motivation, result, and scope.**

*[Motivation][motivation], [Coherence][coherence], [Verification][verification], [Proportionality][proportionality]*

The PR body should give reviewers enough context to assess the contribution as a whole. It explains the problem or research goal, the resulting change, and the affected components and kinds of change. One short description may cover all three.

The PR body should identify commits outside the main topic and explain their inclusion. Section formats are described in [CONVENTIONS.md](CONVENTIONS.md#pr-titles-and-descriptions).

<a id="p.single-commit-record"></a>

**[P.single-commit-record](#p.single-commit-record). A single-commit PR's message must explain the PR's motivation, result, and scope.**

*[Motivation][motivation], [Coherence][coherence], [Provenance][provenance], [Proportionality][proportionality]*

When a single-commit PR is fast-forwarded, there is no merge message to preserve its overview. The commit message must therefore include the PR's motivation, result, and scope, along with source records when applicable.

<a id="p.source-credit"></a>

**[P.source-credit](#p.source-credit). Commits containing copied or adapted work must cite its source and preserve author credit.**

*[Provenance][provenance]*

Source references let readers trace inherited work and preserve its contributors' credit. A commit containing copied or adapted work should identify the source revision and explain local differences in behavior or design. When several commits are folded together, all their source references should remain in the resulting message.

Rewrites must preserve source references and author attribution. Coauthor credit is optional and reserved for actual human joint authorship. Do not add coauthor credit for AI tools or other generators. Credit records do not change responsibility under [P.responsibility](#p.responsibility). Source-trailer formats are described in [CONVENTIONS.md](CONVENTIONS.md#sources-and-credit).

<a id="p.regression-origin"></a>

**[P.regression-origin](#p.regression-origin). Identify a regression's introducing commit when known.**

*[Verification][verification], [Provenance][provenance]*

When a regression's introducing commit is known, the message should identify it with the `Fixes:` record described in [CONVENTIONS.md](CONVENTIONS.md#sources-and-credit). This lets readers trace the regression to its cause. If the introducing commit cannot be established, omit that record.

<a id="p.imported-work"></a>

**[P.imported-work](#p.imported-work). Port and Sync PRs must distinguish imported work, adaptations, omissions, and local changes.**

*[Coherence][coherence], [Provenance][provenance], [Proportionality][proportionality]*

A Port or Sync description should identify the source PRs or revisions and explain how the local result differs. That includes adaptations, conflict resolutions, omissions, and any local work, so reviewers can compare the upstream and local changes. Independent local work in a Port still follows [P.port-scope](#p.port-scope). Scope-group formats are described in [CONVENTIONS.md](CONVENTIONS.md#pr-titles-and-descriptions).

<a id="p.upstream-explanations"></a>

**[P.upstream-explanations](#p.upstream-explanations). Reuse upstream explanations only when they cover the adopted design and its local assumptions.**

*[Motivation][motivation], [Coherence][coherence], [Provenance][provenance], [Proportionality][proportionality]*

A Port or Sync may refer readers to an upstream explanation when it explains the adopted design and its assumptions still hold locally. This avoids duplicating the reasoning and keeps it attached to the original work.

The local PR should link the explanation and summarize why the work is needed here and what result it brings. Any missing reasoning or local design differences still need an explanation in the local PR.

## Reviewing and revising

Resolve questions about the contribution's behavior, design, and readiness.

<a id="p.review-blockers"></a>

**[P.review-blockers](#p.review-blockers). Explain why a requested change is needed before merging.**

*[Responsibility][responsibility], [Coordination][coordination]*

A reviewer who asks for a change that must be made before merging should explain why it is necessary. The explanation should identify a required rule under [P.rules](#p.rules) that the contribution does not follow, or describe what would go wrong if the contribution were merged as written. For concerns about correctness, usability, documentation, or maintenance, the reviewer should explain the specific consequences.

Reviewers should present preferences as suggestions. If a rule's meaning is unclear, the reviewer should ask for clarification.

<a id="p.follow-ups"></a>

**[P.follow-ups](#p.follow-ups). Do not delay a ready contribution for independent follow-up work.**

*[Coherence][coherence], [Proportionality][proportionality]*

Once review blockers are resolved, the contribution can proceed towards landing. Newly discovered work belongs in another PR unless it is needed to implement or verify the current contribution. Independent follow-up work should not hold up a ready contribution or other work that depends on it.

The PR should identify work explicitly postponed from the contribution and explain why it was postponed. Preserve that record when landing. Possible future improvements are not deferred commitments.

## Landing the change

Prepare the reviewed contribution for `main` and record its integration. Substantive changes made during preparation return to review.

<a id="p.commit-buildability"></a>

**[P.commit-buildability](#p.commit-buildability). Finalize each commit as a buildable unit.**

*[Coherence][coherence], [Verification][verification], [Proportionality][proportionality]*

Each final commit should express one idea under [P.change-scope](#p.change-scope) and leave the project buildable, so maintainers can investigate regressions without first repairing intermediate states. If separating commits would require placeholders or break the build, they should be combined.

Review fixups are folded into the commits they complete before landing. Their messages may remain brief until that cleanup. Final editorial polish follows [P.editorial-cleanup](#p.editorial-cleanup).

<a id="p.rebase-timing"></a>

**[P.rebase-timing](#p.rebase-timing). Rebase during final integration by default.**

*[Coordination][coordination], [Proportionality][proportionality]*

While work is under review, a branch needs an update when dependencies or conflicts require it. Contributors are not expected to rebase every open branch after each merge. Final integration normally includes a rebase onto current `main`.

The person rebasing should coordinate the rewrite under [P.reviewer-tasks](#p.reviewer-tasks), including with contributors whose branches depend on the replaced commits. If rebasing would disrupt shared work, the contributors and maintainer should agree on another integration method.

<a id="p.conflict-resolution"></a>

**[P.conflict-resolution](#p.conflict-resolution). Resolve integration conflicts on the PR branch before landing.**

*[Coherence][coherence], [Coordination][coordination]*

Integration conflicts are resolved on the PR branch, where reviewers can inspect the resolutions. Those resolutions can change behavior, so substantive changes need an explanation and a return to review before landing. The landing merge must introduce no further conflict-resolution edits.

<a id="p.merge-method"></a>

**[P.merge-method](#p.merge-method). Use merge commits for multi-commit PRs and default to fast-forwards for single-commit PRs.**

*[Coherence][coherence], [Provenance][provenance], [Proportionality][proportionality]*

The number of commits after final cleanup determines how the PR lands. A multi-commit PR uses a merge commit whose message explains the contribution as a whole. A single-commit PR is fast-forwarded by default because its commit message already provides that record.

The final commits are preserved without squashing. For a single-commit PR, the PR number is added to the subject through an authorized amendment under [P.editorial-cleanup](#p.editorial-cleanup). Message formats and commands are described in the [landing conventions](CONVENTIONS.md#landing).

<a id="p.direct-pushes"></a>

**[P.direct-pushes](#p.direct-pushes). The maintainer may push bounded repairs and current-state documentation directly to `main`.**

*[Responsibility][responsibility], [Coordination][coordination] ↔ [Proportionality][proportionality]*

The core maintainer may push a fix directly to `main` when it addresses an identified fault with known expected behavior and affected callers. Documentation edits may also go directly to `main` when they describe existing behavior or clarify existing rules. This keeps routine corrections from waiting for a separate PR that would add little value.

New design or interfaces, multiple independent behaviors, uncertain impact, and changes to contribution rules need a PR. Other contributors use PRs by default. The same motivation and [component checking instructions](CONVENTIONS.md#build-and-checks) still apply to direct commits.

[motivation]: PRINCIPLES.md#motivation
[coherence]: PRINCIPLES.md#coherence
[verification]: PRINCIPLES.md#verification
[provenance]: PRINCIPLES.md#provenance
[responsibility]: PRINCIPLES.md#responsibility
[coordination]: PRINCIPLES.md#coordination
[proportionality]: PRINCIPLES.md#proportionality
