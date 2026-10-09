# Contributing

Read [PRINCIPLES.md](PRINCIPLES.md) and the policy outline below before contributing. The outline states all shared requirements and permissions. The remaining sections, [CONVENTIONS.md](CONVENTIONS.md), and the [workflow guide](documentation/contributing-workflow.md) are optional references. They explain rationale, defaults, preferences, and procedures without adding requirements.

## Policy outline

Each policy ID links to its optional explanation.

**Working together**

- [P.rules](#p.rules). Follow the requirements in this outline and agree exceptions with the core maintainer before proceeding.

  Discuss departures from project defaults when they affect shared interfaces, meaning, compatibility, or another contributor’s work. Preferences alone do not block merging.

- [P.responsibility](#p.responsibility). Take responsibility for the work you submit, regardless of tools or assistance.

  Understand your changes well enough to explain them. Disclose tool use when needed to explain a research method, result, or limitation. Routine AI disclosures are not required.

- [P.final-cleanup](#p.final-cleanup). The core maintainer may polish existing comments and commit messages and prepare reviewed commits during final integration.

  Without separate approval, this permits meaning-preserving wording and formatting corrections, formatting existing source trailers, adding a single-commit PR number, and folding, combining, or reordering reviewed commits for coherence and buildability. Combining or reordering must preserve final file contents on the same base. All cleanup must preserve motivation, sources, and author credit. Keep independent changes distinguishable. The maintainer may amend, rebase, and publish with a lease after coordinating dependent branches, and must report the cleanup at merge. New explanations, factual corrections, changed assumptions or motivation, ambiguous intent, attribution changes, and PR metadata changes need discussion. Executable-code changes and substantive conflict resolutions return to review.

**Shaping the work**

- [P.change-scope](#p.change-scope). Each commit should express one idea, and each PR should develop one main topic.

  Incidental commits may accompany the main topic when a separate PR adds little value. Keep them distinct, explain their inclusion, and keep the topic stable during review. Limit each Port to one upstream PR and necessary local adaptations.

- [P.invariants](#p.invariants). Preserve the guarantees callers rely on.

  Construction must establish those guarantees, and exposed updates must preserve them.

- [P.renames](#p.renames). Agree when a temporary compatibility alias will be removed.

  Record the consumer’s migration obstacle and agree the removal point with the core maintainer.

- [P.documentation](#p.documentation). Keep comments and documentation accurate to the current system.

  Put accounts of what changed and why in change records.

**Presenting the change**

- [P.commit-explanations](#p.commit-explanations). Each final commit message should explain the motivation and resulting change.

  For refactors, identify the structural limitation and how the new structure addresses it. A sufficient subject needs no body. Identify a regression’s introducing commit when known.

- [P.pr-explanations](#p.pr-explanations). Each PR body should explain its motivation, result, and scope.

  One short description may cover all three.

- [P.source-credit](#p.source-credit). Commits containing copied or adapted work must cite its source and preserve author credit.

  Identify the source revision and explain local differences. Preserve all references and author attribution when rewriting or folding commits. Coauthor credit is optional and limited to actual human joint authorship. Do not credit tools as coauthors.

- [P.imported-work](#p.imported-work). Distinguish imported work from local changes and explain omissions.

  Identify the sources and explain adaptations and conflict resolutions.

**Reviewing and revising**

- [P.reviewer-tasks](#p.reviewer-tasks). Announce review tasks and coordinate edits with the contributor.

  Let the contributor take announced tasks instead, except final editorial polish. Discuss behavior, design, or stated reasoning changes before making them. Agree history rewrites and PR metadata edits unless covered by P.final-cleanup.

- [P.review-blockers](#p.review-blockers). Ground review blockers in required rules or concrete problems.

  Identify the required rule or explain what would go wrong if merged. Present preferences as suggestions and ask for clarification when a rule is unclear.

- [P.follow-ups](#p.follow-ups). Do not delay a ready contribution for independent follow-up work.

  Record deliberately postponed tasks and their reasons, and preserve the record when landing. Possible improvements are not deferred commitments.

**Landing the change**

- [P.commit-buildability](#p.commit-buildability). Finalize each commit as a buildable unit.

  Fold review fixups into the commits they complete. Combine commits when separation would require placeholders or break the build.

- [P.conflict-resolution](#p.conflict-resolution). Resolve integration conflicts on the PR branch before landing.

  Return substantive resolutions to review. The landing merge must introduce no further conflict-resolution edits.

- [P.merge-method](#p.merge-method). Preserve final commits and record the contribution when landing.

  Land multi-commit PRs with a merge commit explaining the whole contribution. Count commits after cleanup and preserve them without squashing during landing. A single-commit PR’s message must carry its motivation, result, and scope. Add its PR number through authorized cleanup.

- [P.direct-pushes](#p.direct-pushes). The maintainer may push bounded repairs and current-state documentation directly to `main`.

  Repairs must address an identified fault with known expected behavior and affected callers. Documentation edits must describe existing behavior or clarify existing rules. New designs or interfaces, multiple independent behaviors, uncertain impact, and changes to contribution rules need a PR. Other contributors use PRs by default. Direct changes must meet the same requirements.

## Rationale and application details (optional)

These sections explain the outline and link to ways of applying it. Policy IDs stay stable when wording or placement changes. Each policy links to its supporting principles. `↔` marks a tradeoff.

### Working together

<a id="p.rules"></a>

**[P.rules](#p.rules). Follow the requirements in this outline and agree exceptions with the core maintainer before proceeding.**

*Requirement. [Responsibility][responsibility], [Coordination][coordination]*

Shared requirements protect contributors and the project. Defaults and preferences settle routine choices without requiring discussion of every difference.

The outline is the source of shared contribution requirements and permissions. Exceptions need agreement with the core maintainer before proceeding. Conventions and component guides supply recommended forms and procedures.

Follow project defaults unless another approach better serves the work. Discuss departures when they affect shared interfaces, meaning, compatibility, or another contributor’s work. Guidance and editorial preferences help contributors write and organize their work. They do not require an explanation for every departure. Optional steps may be skipped.

Reviewers should distinguish requirements from recommendations when requesting changes. Differences in editorial preference alone should not block merging. Concrete problems can still be raised under [P.review-blockers](#p.review-blockers).

Contributors are welcome to raise issues with this guide or CONVENTIONS.md when they have ideas for improving the contribution process.

<a id="p.responsibility"></a>

**[P.responsibility](#p.responsibility). Take responsibility for the work you submit, regardless of tools or assistance.**

*Requirement. [Verification][verification], [Responsibility][responsibility]*

Contributors are responsible for the work they submit, and reviewers are responsible for the edits they make. Contributors must understand their changes well enough to explain them and answer review questions. AI tools, code generators, and other assistance do not change these responsibilities or the contribution requirements.

Routine AI-use disclosures are not required. Explain tool use when it is part of the research method or necessary to understand a result or its limits. Contributors remain responsible for submitted work, including work copied or adapted from others.

<a id="p.final-cleanup"></a>

**[P.final-cleanup](#p.final-cleanup). The core maintainer may polish existing comments and commit messages and prepare reviewed commits during final integration.**

*Permission. [Coherence][coherence], [Provenance][provenance], [Responsibility][responsibility] ↔ [Coordination][coordination]*

The core maintainer bears most of the lasting cost of unclear prose and fragmented history. During final integration, the maintainer may perform the routine cleanup below without asking for separate approval.

**Editorial corrections**

- Correct spelling, grammar, formatting, and wording in existing comments while preserving their facts, constraints, and reasons.
- Correct spelling, grammar, and wording in commit subjects and bodies without changing their meaning or motivation.
- Apply commit-message format and wrapping conventions.
- Format existing source and attribution trailers without changing their facts or credit.
- Add the PR number to a single-commit PR's commit subject.

**Commit preparation**

- Fold review fixups into the commits they complete.
- Combine or reorder reviewed commits when needed to make them coherent and buildable under [P.commit-buildability](#p.commit-buildability).

Combining or reordering commits must preserve the branch's final file contents on the same base. Rebasing onto a new base follows [P.conflict-resolution](#p.conflict-resolution). Editorial edits are limited to the prose and record corrections above. Preserve each change's motivation, source references, and author credit. Keep independent changes distinguishable under [P.change-scope](#p.change-scope).

The maintainer may amend commits, rebase them, and publish the rewritten PR branch using a lease for this cleanup. The [workflow guide](documentation/contributing-workflow.md#revising-reviewed-commits) gives the commands. Before rewriting, coordinate with contributors whose branches depend on the affected commits. When merging, tell the contributor what was edited and how the commits were reorganized.

New explanations, factual corrections, changes to assumptions or motivation, and resolving ambiguous intent need discussion under [P.reviewer-tasks](#p.reviewer-tasks). Changes to attribution or PR metadata also follow P.reviewer-tasks. Executable-code changes and substantive conflict resolutions return to review under [P.conflict-resolution](#p.conflict-resolution).

### Shaping the work

<a id="p.change-scope"></a>

**[P.change-scope](#p.change-scope). Each commit should express one idea, and each PR should develop one main topic.**

*Requirement. [Coherence][coherence] ↔ [Proportionality][proportionality]*

Edits that implement, test, or explain the same idea belong together. Unrelated ideas should have separate commits so readers can understand and review each change on its own.

A PR may include commits outside its main topic when a separate PR would add review and landing overhead without enough practical benefit. Those commits should remain distinct, and the PR body should explain why they belong. A Port is limited to one upstream PR and its necessary local adaptations. The [porting conventions](CONVENTIONS.md#c.ports-syncs.scope) explain this scope.

While a PR is under review, its planned topic should remain stable. Newly discovered independent work normally belongs in another PR, unless the same grouping exception applies. Once the contribution is ready, [P.follow-ups](#p.follow-ups) explains how to handle follow-up work. Final commit preparation follows [P.commit-buildability](#p.commit-buildability).

<a id="p.invariants"></a>

**[P.invariants](#p.invariants). Preserve the guarantees callers rely on.**

*Requirement. [Coherence][coherence], [Verification][verification]*

Callers need to know which guarantees hold when they use a value or operation. Construction must establish those guarantees, and exposed updates must preserve them. The [type and data conventions](CONVENTIONS.md#types-and-data) describe ways to enforce them.

<a id="p.renames"></a>

**[P.renames](#p.renames). Agree when a temporary compatibility alias will be removed.**

*Requirement. [Coherence][coherence] ↔ [Coordination][coordination]*

A compatibility alias creates a migration obligation that can outlast the contribution. When a consumer cannot migrate in the same change, record the obstacle and agree with the core maintainer on when the alias will be removed. Complete renames are the default under [C.names.renames](CONVENTIONS.md#c.names.renames).

<a id="p.documentation"></a>

**[P.documentation](#p.documentation). Keep comments and documentation accurate to the current system.**

*Requirement. [Coherence][coherence], [Verification][verification]*

Readers should be able to rely on descriptions of the system without knowing an earlier implementation. Describe current behavior, constraints, and lasting reasons. Put accounts of what changed and why in change records. Placement and duplication follow the [documentation conventions](CONVENTIONS.md#c.documentation.locations).

### Presenting the change

<a id="p.commit-explanations"></a>

**[P.commit-explanations](#p.commit-explanations). Each final commit message should explain the motivation and resulting change.**

*Requirement. [Motivation][motivation], [Coherence][coherence]*

A commit message should let readers understand why the change was needed and what it accomplishes without having seen the original discussion. Motivation explains the prior problem, limitation, or research goal. Solution describes the resulting change that addresses it. For a refactor, the explanation must identify the structural limitation and show why the new structure addresses it.

When the subject already conveys the required explanation, the message does not need a body. Source records still follow [P.source-credit](#p.source-credit). Identify a known regression’s introducing commit. The [regression-record convention](CONVENTIONS.md#c.sources.regressions) supplies a recommended format.

<a id="p.pr-explanations"></a>

**[P.pr-explanations](#p.pr-explanations). Each PR body should explain its motivation, result, and scope.**

*Requirement. [Motivation][motivation], [Coherence][coherence], [Verification][verification], [Proportionality][proportionality]*

The PR body should give reviewers enough context to assess the contribution as a whole. It explains the problem or research goal, the resulting change, and the affected components and kinds of change. One short description may cover all three.

The PR body should identify commits outside the main topic and explain their inclusion. Section formats are described in [CONVENTIONS.md](CONVENTIONS.md#pr-titles-and-descriptions).

<a id="p.source-credit"></a>

**[P.source-credit](#p.source-credit). Commits containing copied or adapted work must cite its source and preserve author credit.**

*Requirement. [Provenance][provenance]*

Source references let readers trace inherited work and preserve its contributors' credit. A commit containing copied or adapted work should identify the source revision and explain local differences in behavior or design. When several commits are folded together, all their source references should remain in the resulting message.

Rewrites must preserve source references and author attribution. Credit records do not change responsibility under [P.responsibility](#p.responsibility). Coauthor credit is optional and limited to actual human joint authorship. Tools are not coauthors. Recommended source-trailer formats are described in [CONVENTIONS.md](CONVENTIONS.md#sources-and-credit).

<a id="p.imported-work"></a>

**[P.imported-work](#p.imported-work). Distinguish imported work from local changes and explain omissions.**

*Requirement. [Coherence][coherence], [Provenance][provenance], [Proportionality][proportionality]*

Reviewers need to compare the source work with the local result. Identify the sources and explain adaptations, omissions, and independent local changes, including conflict resolutions. The [Port and Sync conventions](CONVENTIONS.md#ports-and-syncs) recommend description groups and explain when upstream explanations can be reused.

### Reviewing and revising

Resolve questions about the contribution's behavior, design, and readiness.

<a id="p.reviewer-tasks"></a>

**[P.reviewer-tasks](#p.reviewer-tasks). Announce review tasks and coordinate edits with the contributor.**

*Requirement. [Responsibility][responsibility], [Coordination][coordination]*

Reviewers should tell the contributor which tasks they plan to take on, including edits, commits, pushes, history rewrites, and PR metadata changes. This lets the contributor avoid duplicate work or take on those tasks themselves. Final editorial polish remains the maintainer's responsibility under [P.final-cleanup](#p.final-cleanup).

Before changing behavior, design, or the contributor's stated reasoning, the reviewer should discuss the change with the contributor. History rewrites and PR metadata edits also need agreement unless they fall within P.final-cleanup.

<a id="p.review-blockers"></a>

**[P.review-blockers](#p.review-blockers). Ground review blockers in required rules or concrete problems.**

*Requirement. [Responsibility][responsibility], [Coordination][coordination]*

A reviewer who asks for a change that must be made before merging should explain why it is necessary. The explanation should identify a required rule under [P.rules](#p.rules) that the contribution does not follow, or describe what would go wrong if the contribution were merged as written. For concerns about correctness, usability, documentation, or maintenance, the reviewer should explain the specific consequences.

Reviewers should present preferences as suggestions. If a rule's meaning is unclear, the reviewer should ask for clarification.

<a id="p.follow-ups"></a>

**[P.follow-ups](#p.follow-ups). Do not delay a ready contribution for independent follow-up work.**

*Requirement. [Coherence][coherence], [Proportionality][proportionality]*

Once review blockers are resolved, the contribution can proceed towards landing. Newly discovered work belongs in another PR unless it is needed to implement or verify the current contribution. Independent follow-up work should not hold up a ready contribution or other work that depends on it.

The PR should identify work explicitly postponed from the contribution and explain why it was postponed. Preserve that record when landing. Possible future improvements are not deferred commitments.

### Landing the change

Prepare the reviewed contribution for `main` and record its integration. Substantive changes made during preparation return to review.

<a id="p.commit-buildability"></a>

**[P.commit-buildability](#p.commit-buildability). Finalize each commit as a buildable unit.**

*Requirement. [Coherence][coherence], [Verification][verification], [Proportionality][proportionality]*

Each final commit should express one idea under [P.change-scope](#p.change-scope) and leave the project buildable, so maintainers can investigate regressions without first repairing intermediate states. If separating commits would require placeholders or break the build, they should be combined.

Review fixups are folded into the commits they complete before landing. Their messages may remain brief until that cleanup. The maintainer may perform this preparation under [P.final-cleanup](#p.final-cleanup).

<a id="p.conflict-resolution"></a>

**[P.conflict-resolution](#p.conflict-resolution). Resolve integration conflicts on the PR branch before landing.**

*Requirement. [Coherence][coherence], [Coordination][coordination]*

Integration conflicts are resolved on the PR branch, where reviewers can inspect the resolutions. Those resolutions can change behavior, so substantive changes need an explanation and a return to review before landing. The landing merge must introduce no further conflict-resolution edits.

<a id="p.merge-method"></a>

**[P.merge-method](#p.merge-method). Preserve final commits and record the contribution when landing.**

*Requirement. [Coherence][coherence], [Provenance][provenance], [Proportionality][proportionality]*

The history should preserve reviewed units of work and explain their integration. Land multi-commit PRs with a merge commit that explains the contribution as a whole. Count commits after cleanup and preserve the resulting commits without squashing during landing.

For single-commit PRs, the [integration default](CONVENTIONS.md#c.integration.method) is a fast-forward. Their commit message supplies the permanent record under [C.single-commit-record](CONVENTIONS.md#c.single-commit-record). Add the PR number through authorized final cleanup under [P.final-cleanup](#p.final-cleanup).

<a id="p.direct-pushes"></a>

**[P.direct-pushes](#p.direct-pushes). The maintainer may push bounded repairs and current-state documentation directly to `main`.**

*Permission. [Responsibility][responsibility], [Coordination][coordination] ↔ [Proportionality][proportionality]*

The core maintainer may push a fix directly to `main` when it addresses an identified fault with known expected behavior and affected callers. Documentation edits may also go directly to `main` when they describe existing behavior or clarify existing rules. This keeps routine corrections from waiting for a separate PR that would add little value.

New design or interfaces, multiple independent behaviors, uncertain impact, and changes to contribution rules need a PR. Other contributors use PRs by default. Direct commits must meet the same outline requirements. The [workflow guide](documentation/contributing-workflow.md#build-and-checks) describes available checks.

[motivation]: PRINCIPLES.md#motivation
[coherence]: PRINCIPLES.md#coherence
[verification]: PRINCIPLES.md#verification
[provenance]: PRINCIPLES.md#provenance
[responsibility]: PRINCIPLES.md#responsibility
[coordination]: PRINCIPLES.md#coordination
[proportionality]: PRINCIPLES.md#proportionality
