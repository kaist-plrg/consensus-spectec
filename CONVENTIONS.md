# Conventions

Conventions settle routine decisions so contributors can reuse them. As a rule of thumb, document a routine choice here after similar decisions have been made three times. State the choice and when it applies.

This is an optional reference. [PRINCIPLES.md](PRINCIPLES.md) and the policy outline in [CONTRIBUTING.md](CONTRIBUTING.md#policy-outline) are the shared reading baseline. Defaults describe the usual approach, and editorial preferences guide writing and final polish. This document adds no requirements. References to obligations restate the outline. See the [workflow guide](documentation/contributing-workflow.md) for command recipes.

Convention IDs name topics and stay stable when rules move or their wording changes. Links below convention groups identify the shared requirements or principles that support them. Entries are defaults unless marked as editorial preferences or identified as restatements of an outline requirement. Defaults allow judgment under [P.rules](CONTRIBUTING.md#p.rules).

## Across media

<a id="c.established-forms"></a>**[C.established-forms](#c.established-forms). Prefer established code and prose forms when alternatives offer no clear benefit.**

*Default. Principles [Coherence](PRINCIPLES.md#coherence), [Proportionality](PRINCIPLES.md#proportionality).*

Familiar forms let readers focus on meaning and avoid repeated decisions. When alternatives express the same idea equally clearly, follow the surrounding code or prose. Use a different form when it makes an operation, dependency, or relationship clearer.

As general writing guidance, write for readers who do not share your context. Explain what the surrounding artifact cannot readily show. The rules below make sentence structure, terminology, and punctuation easier to follow.

<a id="c.prose"></a>

**[C.prose](#c.prose). Prose clarity**

*Editorial preference. Policies [P.documentation](CONTRIBUTING.md#p.documentation), [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations), [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations).*

Apply these conventions to prose sentences.

**Sentence structure**

- <a id="c.prose.focus"></a>**[C.prose.focus](#c.prose.focus). Keep one main idea per sentence.** Split sentences that make separate claims readers need to assess independently.

- <a id="c.prose.flow"></a>**[C.prose.flow](#c.prose.flow). Order information from familiar context to new information.** Readers should be able to follow the sentence from left to right.

- <a id="c.prose.subject-verbs"></a>**[C.prose.subject-verbs](#c.prose.subject-verbs). Keep subjects close to their verbs.**

**Actors and references**

- <a id="c.prose.actors"></a>**[C.prose.actors](#c.prose.actors). Make clear who or what performs each action.** Name the actor when the sentence would otherwise leave it unclear. Assign actions to the entities that actually perform them.

- <a id="c.prose.pronouns"></a>**[C.prose.pronouns](#c.prose.pronouns). Use pronouns only when their referents are clear.** Repeat a name when a pronoun could refer to more than one entity.

- <a id="c.prose.explicit-nouns"></a>**[C.prose.explicit-nouns](#c.prose.explicit-nouns). State what is being described or compared.** Include the noun when readers would otherwise have to guess what has the stated property.

- <a id="c.prose.modifiers"></a>**[C.prose.modifiers](#c.prose.modifiers). Place descriptive phrases next to the words they describe.** Rewrite a phrase when readers could connect it to the wrong person or thing.

**Word choice**

- <a id="c.prose.terms"></a>**[C.prose.terms](#c.prose.terms). Prefer defining unfamiliar technical terms before relying on them.** Use plain language for terms the intended reader is unlikely to know. For established project terms, link an existing definition when needed.

- <a id="c.prose.literal-language"></a>**[C.prose.literal-language](#c.prose.literal-language). Prefer literal descriptions to metaphors.** Use the actual operation, constraint, or relationship when a metaphor would leave readers to infer the meaning.

**Punctuation**

These punctuation choices support [one main idea per sentence](#c.prose.focus) and [the progression from familiar to new information](#c.prose.flow).

- <a id="c.prose.punctuation"></a>**[C.prose.punctuation](#c.prose.punctuation). Replace semicolons, colons, and em dashes with clearer punctuation or separate sentences.** Use periods, commas, or parentheses according to the relationship being expressed. Preserve punctuation required by code, URLs, message syntax, source references, and exact quotations.

- <a id="c.prose.parentheses"></a>**[C.prose.parentheses](#c.prose.parentheses). Prefer parentheses only for brief qualifications.** Put a separate claim or an essential step in the explanation in its own sentence.

## Code

The [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/#naming) explain naming from a caller's perspective. Robert C. Martin's [Clean Code](https://www.oreilly.com/library/view/clean-code-a/9780136083238/) includes chapters on meaningful names and functions. These are optional background reading. The conventions below state this project's choices.

### Names and boundaries

As general guidance, use names and interfaces to make a component's meaning and responsibility clear to its callers. Choose names from the project's vocabulary and use them consistently for the same concept. As a default, keep code that maintains the same invariant together. [P.invariants](CONTRIBUTING.md#p.invariants) requires operations to preserve the guarantees callers rely on.

As guidance, spend naming effort in proportion to how widely and how long a name is used. The default order of attention is module names, function names, labeled parameters, positional parameters, local bindings, and bindings in lambdas or match arms. Short names are appropriate when the surrounding code makes their roles immediately clear.

<a id="c.names"></a>

**[C.names](#c.names). Names**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policy [P.renames](CONTRIBUTING.md#p.renames).*

- <a id="c.names.modules"></a>**[C.names.modules](#c.names.modules). Name modules for the responsibilities they own.**

- <a id="c.names.functions"></a>**[C.names.functions](#c.names.functions). Name functions for their operations or results.** Prefer verbs or verb-led phrases for actions and transformations, including pure AST passes. Nouns are appropriate for projections and computed properties. A verb-led name does not imply mutation.

- <a id="c.names.parameters"></a>**[C.names.parameters](#c.names.parameters). Name parameters for what callers supply.** Use role names that can be referenced clearly in the function's contract.

- <a id="c.names.locals"></a>**[C.names.locals](#c.names.locals). Name local values for their roles in the computation.**

- <a id="c.names.helpers"></a>**[C.names.helpers](#c.names.helpers). Name recursive helpers for what they compute or traverse.** Do not use generic names such as `aux`, `go`, or `loop` as defaults.

- <a id="c.names.type-repetition"></a>**[C.names.type-repetition](#c.names.type-repetition). Avoid repeating type information in OCaml variable names.** Name values for their roles. OCaml is statically typed, so readers can infer type information from context or inspect it in an editor.

- <a id="c.names.conversions"></a>**[C.names.conversions](#c.names.conversions). Prefer `to_x` and `of_x` for conversions.** `to_x` names the result representation, and `of_x` names the input representation. The module name identifies the other side of the conversion.

- <a id="c.names.predicates"></a>**[C.names.predicates](#c.names.predicates). Name predicates for the conditions they test.** Use forms such as `is_...`, `has_...`, `contains`, or an established relation such as `eq`.

- <a id="c.names.arguments"></a>**[C.names.arguments](#c.names.arguments). Prefer argument labels when positional roles would be unclear at call sites.** Use labels to distinguish arguments with the same type but different roles and to explain callbacks or configuration options. Keep the main input positional when the function name makes its role clear.

Check existing uses of a concept before choosing its name. Evaluate a name at its call sites as well as in its declaration. Names are part of the specification vocabulary, so misleading names can obscure semantic errors.

Rename a component once its boundary and responsibility support the new name. Public APIs should express the intended semantic model even when dependency constraints require different internal module paths. Prefer explicit organization over broad buckets such as `core` when distinct responsibilities can be named.

<a id="c.names.renames"></a>**[C.names.renames](#c.names.renames). Rename declarations and callers together by default.**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policy [P.renames](CONTRIBUTING.md#p.renames).*

Do not retain compatibility aliases by default. Two names can suggest different meanings. When a consumer cannot migrate in the same change, record the obstacle and agree the alias’s removal under [P.renames](CONTRIBUTING.md#p.renames).

### Types and data

<a id="c.types"></a>

**[C.types](#c.types). Type constraints**

*Default. Policy [P.invariants](CONTRIBUTING.md#p.invariants).*

Types let callers rely on constraints without checking them at every use. As guidance, make invalid states unrepresentable with the simplest type that captures the constraint.

- <a id="c.types.alternatives"></a>**[C.types.alternatives](#c.types.alternatives). Prefer representing alternatives with their required data.** Use variant constructors for cases that require different data. Avoid flags and optional fields that allow combinations the program cannot handle.

- <a id="c.types.construction"></a>**[C.types.construction](#c.types.construction). Protect invariants at construction.** When callers rely on a value already being validated, use an abstract or private type with checked constructors. Every exposed operation that constructs or updates a value must preserve those constraints.

- <a id="c.types.runtime-checks"></a>**[C.types.runtime-checks](#c.types.runtime-checks). Keep checks for constraints the type does not enforce.** A type may guarantee a value's structure without guaranteeing its meaning or its relationship to other values. Validate those remaining constraints at runtime.

As guidance, prefer explicit checks when encoding a constraint in a type would make ordinary operations harder to understand.

### Abstractions and interfaces

As a default, give abstractions responsibilities that current callers need. An abstraction adds a concept readers must learn, so hypothetical future uses alone do not justify generic options or extension points. This applies [YAGNI](https://martinfowler.com/bliki/Yagni.html) to abstractions.

Names and interfaces should express the responsibility, what callers supply, and what they can rely on. Callers should be able to use operations without knowing their internal steps. Inputs that affect results should be explicit by default.

<a id="c.abstractions"></a>

**[C.abstractions](#c.abstractions). Abstraction boundaries**

*Default. Principle [Coherence](PRINCIPLES.md#coherence).*

- <a id="c.abstractions.operations"></a>**[C.abstractions.operations](#c.abstractions.operations). Extract meaningful operations.** Give each helper or module an operation or responsibility that its callers can name. One caller can justify an abstraction when it expresses a distinct operation.

- <a id="c.abstractions.sharing"></a>**[C.abstractions.sharing](#c.abstractions.sharing). Share implementations only when callers need the same operation and constraints.** Similar syntax alone does not justify combining code with different meanings or reasons to change.

- <a id="c.abstractions.exposure"></a>**[C.abstractions.exposure](#c.abstractions.exposure). Expose what callers need.** Keep representations private when callers need operations rather than direct inspection. Expose data when inspecting it is part of the caller's task.

- <a id="c.abstractions.io"></a>**[C.abstractions.io](#c.abstractions.io). Separate computation from loading and saving data by default.** Functions that compute results should accept data directly. Functions whose purpose is loading or saving data should handle the corresponding I/O.

### Mutation

As general guidance, prefer functional updates that return new values over mutation. Returning an updated value makes the change explicit to callers. Other computations can keep using the original value. When mutation is useful, make its dependencies and ownership explicit.

<a id="c.mutation"></a>

**[C.mutation](#c.mutation). Mutation**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policy [P.invariants](CONTRIBUTING.md#p.invariants).*

- <a id="c.mutation.inputs"></a>**[C.mutation.inputs](#c.mutation.inputs). Pass inputs as arguments instead of reading mutable global state by default.** Pass settings and environments that affect a result at the call site. This lets readers see the function's dependencies.

- <a id="c.mutation.ownership"></a>**[C.mutation.ownership](#c.mutation.ownership). Give mutable state a clear owner and lifetime.** Keep state needed by one operation local to that operation. Put shared state and the operations that update it in the component responsible for maintaining it.

- <a id="c.mutation.recursion"></a>**[C.mutation.recursion](#c.mutation.recursion). Prefer readable recursion or folds over mutable references when they make control flow clearer.**

Mutation can serve caches, registries, usage tracking, and resource management.

### OCaml

<a id="c.ocaml"></a>

**[C.ocaml](#c.ocaml). OCaml conventions**

*Default. Principles [Coherence](PRINCIPLES.md#coherence), [Proportionality](PRINCIPLES.md#proportionality).*

- <a id="c.ocaml.casing"></a>**[C.ocaml.casing](#c.ocaml.casing). Follow OCaml's casing conventions.** Use `snake_case` for values and types and `PascalCase` for modules and constructors.

- <a id="c.ocaml.callback-wrappers"></a>**[C.ocaml.callback-wrappers](#c.ocaml.callback-wrappers). Name setup-and-teardown callback wrappers `with_*`.** The name identifies the resource or context available to the callback.

- <a id="c.ocaml.accumulators"></a>**[C.ocaml.accumulators](#c.ocaml.accumulators). Prefer accumulator-first parameter order for accumulator updates.** Follow `fold_left`.

- <a id="c.ocaml.application"></a>**[C.ocaml.application](#c.ocaml.application). Use `@@` only when it clearly reduces indentation around a single callback body.**

Prefer direct code when handling exceptions.

<a id="c.compiler-layout"></a>

**[C.compiler-layout](#c.compiler-layout). Place compiler code according to its responsibility.**

*Default. Principle [Coherence](PRINCIPLES.md#coherence).*

| Responsibility | Location |
| --- | --- |
| Semantic operations usable without command-line handling | `spectec/lib/` |
| Shared argument parsing and command coordination | `spectec/lib/cli/` |
| Executable startup and handoff to the CLI | `spectec/bin/` |

Keep semantic logic out of executable entrypoints so other callers can use it without starting the CLI.

## Comments

<a id="c.comments.purpose"></a>**[C.comments.purpose](#c.comments.purpose). Use comments for constraints and reasons absent from the code.**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policy [P.documentation](CONTRIBUTING.md#p.documentation).*

Names, types, and implementation often supply the explanation. Add a comment when a constraint or reason is not evident from them. Accounts of what changed and why belong in change records under [P.documentation](CONTRIBUTING.md#p.documentation).

Before adding a comment, consider whether a clearer name, smaller function, or stronger type can express the information. Omit comments that only paraphrase code, repeat a name, or label the next block.

A reader should be able to understand a comment without seeing an earlier version of the code.

<a id="c.comments"></a>

**[C.comments](#c.comments). Comment placement and idiom**

*Default. Policy [P.documentation](CONTRIBUTING.md#p.documentation).*

- <a id="c.comments.definitions"></a>**[C.comments.definitions](#c.comments.definitions). Use function definition comments for caller-visible facts not evident from the signature.** For example, explain a required input order here.

- <a id="c.comments.bodies"></a>**[C.comments.bodies](#c.comments.bodies). Use function body comments for non-obvious constraints or choices.** These can explain invariants, external constraints, specification rules, or implementation choices.

- <a id="c.comments.idiom"></a>**[C.comments.idiom](#c.comments.idiom). Match the surrounding code's comment style and density.**

- <a id="c.comments.placement"></a>**[C.comments.placement](#c.comments.placement). Place comments beside the code they explain.** Refer to identifiers visible at that location so readers can connect the explanation to the code.

- <a id="c.comments.callers"></a>**[C.comments.callers](#c.comments.callers). Put caller-specific explanations at the caller.** A condition specific to one use belongs beside that use. A condition all callers must satisfy belongs in the function's contract.

- <a id="c.comments.interfaces"></a>**[C.comments.interfaces](#c.comments.interfaces). Put caller-facing explanations in interface documentation when a separate interface exists.** Readers should find the contract where they look up the operation.

- <a id="c.comments.brevity"></a>**[C.comments.brevity](#c.comments.brevity). Prefer brief comments.** As guidance, one sentence often suffices. If a comment needs several sentences, consider whether clearer names, a smaller function, or a stronger type could express some of the information. Keep the explanation when the code cannot express it.

## Documentation

<a id="c.documentation.locations"></a>**[C.documentation.locations](#c.documentation.locations). Give each explanation an authoritative home by default.**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policy [P.documentation](CONTRIBUTING.md#p.documentation).*

Link to the explanation instead of maintaining competing copies. Put setup and usage guidance in the relevant README, and keep component-specific details near the component.

Comments and documentation describe the current system under [P.documentation](CONTRIBUTING.md#p.documentation).

<a id="c.markdown-wrapping"></a>

**[C.markdown-wrapping](#c.markdown-wrapping). Do not hard-wrap Markdown paragraphs or bullet text.**

*Editorial preference. Principles [Coherence](PRINCIPLES.md#coherence), [Proportionality](PRINCIPLES.md#proportionality).*

Keep each paragraph or bullet's text on one source line and let the renderer wrap it. Preserve line breaks required by code blocks, tables, or other Markdown structure. This also applies to PR bodies.

## Build and checks

<a id="c.checking-instructions"></a>**[C.checking-instructions](#c.checking-instructions). Keep build and checking instructions with the component they apply to.**

*Default. Policy [P.documentation](CONTRIBUTING.md#p.documentation).*

Document formatter versions, commands, and prerequisites in the relevant component guide. Link those instructions instead of maintaining another command list here. The [workflow guide](documentation/contributing-workflow.md#build-and-checks) provides compiler command recipes.

## Change records

<a id="c.change-summaries"></a>**[C.change-summaries](#c.change-summaries). Summarize the conceptual change in commit subjects and PR titles.**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policies [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations), [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations).*

Name the action and affected concept so readers can identify the change before opening its details. A commit subject describes that commit’s idea. A PR title names the contribution’s main topic, and its body accounts for accompanying work.

### Commit messages

<a id="c.commit-format"></a>

**[C.commit-format](#c.commit-format). Commit classification and format**

*Default. Principle [Coherence](PRINCIPLES.md#coherence). Policy [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations).*

<a id="c.commit-format.subject"></a>**[C.commit-format.subject](#c.commit-format.subject). Use `type(scope): summary`, with standard types and the additional `reorg` type.**

Use this format.

```text
type(scope): imperative summary

Motivation describing the prior problem or limitation.

Solution describing the resulting change.
```

<a id="c.commit-format.classification"></a>**[C.commit-format.classification](#c.commit-format.classification). Choose the type by intent and the scope by affected area, regardless of implementation language.**

Commit types include `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `chore`, `perf`, and `style`. Classification applies across implementation languages. The additional `reorg` type covers directory renames, file moves, and layout changes that preserve code structure and behavior. Mechanical caller updates can remain `reorg`. Use `refactor` when responsibilities or APIs change. Use `ci` for CI configuration and automated build, check, or release workflows. Use `chore` for other build configuration or dependencies.

Classify structural or behavioral changes by their own intent, even when they accompany reorganization or formatting. Explain those changes separately. A `reorg` label does not establish behavior preservation by itself.

Choose the narrowest accurate scope, such as `converter`, `cli`, `elaborate`, `il`, `interp`, `instrumentation`, or `targets/p4`.

For documentation changes, choose the scope by topic. Use `docs(principles)` for project principles, `docs(conventions)` for routine conventions, and `docs(contributing)` for contribution policies or changes spanning the contribution process. Name affected documents in the body when that helps readers locate the work.

<a id="c.commit-format.specifications"></a>**[C.commit-format.specifications](#c.commit-format.specifications). Use `spec` or `spec/<target>` scopes for specification work, such as `fix(spec/deneb): correct blob validation`.**

Specification messages should distinguish changes in modeled behavior from changes in notation or organization.

The `spec` commit type is deprecated. Historical `spec` commits denote specification changes. Do not rewrite existing history solely to replace the deprecated type.

<a id="c.commit-format.moves"></a>**[C.commit-format.moves](#c.commit-format.moves). List renamed or moved paths in a `reorg` message as `old -> new` bullets and describe mechanical reference updates.** In a PR, put the rename list beneath the relevant scoped summary bullet using the same path format.

<a id="c.commit-prose"></a>

**[C.commit-prose](#c.commit-prose). Commit prose**

*Editorial preference. Policy [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations).*

<a id="c.commit-prose.subjects"></a>**[C.commit-prose.subjects](#c.commit-prose.subjects). Use imperative subjects.** Name the concept. Put code identifiers in the body, where there is room to explain them. For example, `refactor(cli): group shared flags by role` gives the reader a concept, while its body can identify the modules and flag groups.

<a id="c.commit-prose.bodies"></a>**[C.commit-prose.bodies](#c.commit-prose.bodies). Organize bodies as Motivation followed by Solution, without requiring section headings.** The body explains why and what. Omit the body when the subject already conveys both under [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations). Source citations still follow [P.source-credit](CONTRIBUTING.md#p.source-credit).

<a id="c.commit-prose.motivation-tense"></a>**[C.commit-prose.motivation-tense](#c.commit-prose.motivation-tense). Describe prior problems in past tense by default.** A `Currently, ...` framing is also acceptable.

<a id="c.commit-prose.solution-tense"></a>**[C.commit-prose.solution-tense](#c.commit-prose.solution-tense). Describe solutions in third-person present.** Use forms such as `Adds...`, `Replaces...`, or `The helper is extracted...`. Avoid first-person and future-tense accounts of the solution. These forms also apply to bullets.

<a id="c.commit-prose.grouping"></a>**[C.commit-prose.grouping](#c.commit-prose.grouping). Use paragraphs for a change within one affected area and bullets for changes across distinct areas.** Keep the motivation in prose. Use solution bullets when separating changes to different components or responsibilities makes the result easier to scan. Name concrete identifiers where they help explain the result.

<a id="c.commit-prose.identifiers"></a>**[C.commit-prose.identifiers](#c.commit-prose.identifiers). Use backticks around code identifiers in commit bodies.** This distinguishes identifiers from ordinary prose.

<a id="c.commit-display"></a>

**[C.commit-display](#c.commit-display). Commit character set and wrapping**

*Editorial preference. Principles [Coherence](PRINCIPLES.md#coherence), [Proportionality](PRINCIPLES.md#proportionality).*

<a id="c.commit-display.characters"></a>**[C.commit-display.characters](#c.commit-display.characters). Prefer ASCII in commit-message prose for predictable terminal display.** Use UTF-8 when accurate names, identifiers, or exact source text require it.

<a id="c.commit-display.wrapping"></a>**[C.commit-display.wrapping](#c.commit-display.wrapping). Prefer wrapping commit-message prose at 72 columns.** Leave URLs unbroken. Keep identifiers and verbatim subjects in source records intact even when they exceed that width. Markdown paragraphs and PR bodies follow [C.markdown-wrapping](#c.markdown-wrapping).

### Sources and credit

<a id="c.sources"></a>

**[C.sources](#c.sources). Source and related-revision records**

*Default. Policies [P.source-credit](CONTRIBUTING.md#p.source-credit), [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations), [P.responsibility](CONTRIBUTING.md#p.responsibility).*

In commit messages, source records use full URLs so they remain useful outside GitHub's PR view. Repeat records when a local commit combines several sources. Describe meaningful adaptations in the body. Preserve credit under [P.source-credit](CONTRIBUTING.md#p.source-credit).

<a id="c.sources.commits"></a>**[C.sources.commits](#c.sources.commits). Identify specific source commits with `Original-commit:`.** Use this record for work ported or adapted from an upstream or sibling-repository commit.

<a id="c.sources.trees"></a>**[C.sources.trees](#c.sources.trees). Identify imported files or trees with `Copied-from:`.** Link the source at the revision and path that were copied.

<a id="c.sources.states"></a>**[C.sources.states](#c.sources.states). Identify synchronized source states with `Reference:`.** For an upstream Sync, link the incoming comparison range. For a feature Sync, link the reference revision and the file or tree location being adopted. This records the source state when the work does not follow specific source commits.

Upstream commits retained by a merge already preserve their origins and need no duplicate source records. Local commits adapting specific upstream work still use `Original-commit:`.

<a id="c.sources.cherry-picks"></a>**[C.sources.cherry-picks](#c.sources.cherry-picks). Use `Cherry-picked-from:` as an optional record for transfers between maintained branches.** It helps trace a release backport or another transfer between histories that remain in use. Omit it for a move from a superseded branch. Preserve existing source records under [P.source-credit](CONTRIBUTING.md#p.source-credit). Work imported from another repository follows [C.sources.commits](#c.sources.commits).

<a id="c.sources.port-attribution"></a>**[C.sources.port-attribution](#c.sources.port-attribution). Give `Ported from <project>.` its own paragraph in a port commit.** Place it after the solution and before the source records. Name the actual source project. Explain local adaptations in the solution, separately from this attribution paragraph.

```text
Ported from P4-SpecTec.

Original-commit: https://github.com/kaist-plrg/p4-spectec/commit/<12-character-sha>
```

<a id="c.sources.regressions"></a>**[C.sources.regressions](#c.sources.regressions). Record a known regression's introducing commit as `Fixes: <12-character SHA> ("<subject>")`.** Preserve its full subject. Omit the record when the introducing commit cannot be identified. Hash-length exceptions follow [C.sources.hashes](#c.sources.hashes). This format is an exception to the full-URL default. It may coexist with source records.

<a id="c.sources.hashes"></a>**[C.sources.hashes](#c.sources.hashes). Use 12-character commit hashes in same-repository references and Git URLs that accept abbreviated hashes.** This includes prose references, GitHub shorthand, commit URLs, revision paths, and both endpoints of comparison URLs. Use a longer hash when 12 characters would be ambiguous or the URL requires it. Shortening a hash changes its length while retaining the URL and the identified revision. Preserve hashes in verbatim source quotations and copied commit subjects.

<a id="c.sources.coauthors"></a>**[C.sources.coauthors](#c.sources.coauthors). Credit human coauthors with optional `Co-authored-by: Name <email>` trailers.** Use the trailer only for actual joint authorship and place it in the final record block. Do not add AI or other tool names as coauthors. Existing attribution records remain subject to preservation under [P.source-credit](CONTRIBUTING.md#p.source-credit) and agreement on attribution changes under [P.reviewer-tasks](CONTRIBUTING.md#p.reviewer-tasks).

In PR bodies and merge summaries, GitHub shorthand such as `org/repo@sha` or `org/repo#number` is appropriate. Preserve author information during a rewrite, while allowing Git to record who created the rewritten commit as its committer. The committer field alone does not determine responsibility under [P.responsibility](CONTRIBUTING.md#p.responsibility).

### PR titles and descriptions

Choose a title that identifies the main concept. When several changes form one idea, name that idea. Account for accompanying work in the body under [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations). Concrete titles are easier to understand than abstract labels whose meaning depends on the body.

<a id="c.pr-titles"></a>**[C.pr-titles](#c.pr-titles). Match the PR title form to its category.**

*Default. Policy [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations).*

| Type | Title form |
| --- | --- |
| Refactor | `Refactor <concept>` |
| Feature | A concept-led title without a fixed prefix |
| Port | Use the title form of the feature, fix, test, refactor, or reorg being ported |
| Sync | `Sync <area>` |
| Reorg | `Reorg <concept>` |

A Port names the work being adopted. A Sync names the area being brought to a reference state because it can combine several kinds of change. Other PR categories use a concept-led title describing the change.

<a id="c.pr-body"></a>

**[C.pr-body](#c.pr-body). PR sections**

*Default. Policies [P.change-scope](CONTRIBUTING.md#p.change-scope), [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations), [P.follow-ups](CONTRIBUTING.md#p.follow-ups), [P.responsibility](CONTRIBUTING.md#p.responsibility).*

<a id="c.pr-body.sections"></a>**[C.pr-body.sections](#c.pr-body.sections). Add sections when they answer additional review questions.** Use the standard headings for the purposes defined below. Give additional sections headings that describe their content. Omit sections that repeat information already covered elsewhere.

<a id="c.pr-body.motivation"></a>**[C.pr-body.motivation](#c.pr-body.motivation). Start PR bodies with a Motivation section.** Use `## Motivation` and explain the problem or research goal.

<a id="c.pr-body.concepts"></a>**[C.pr-body.concepts](#c.pr-body.concepts). Use a Core Concepts section when design ideas need a separate explanation.** Under `## Core Concepts`, use `### <concept>` headings for explanations with paragraphs or code examples. Use bolded bullets only when each concept fits compactly in one bullet. Explain how the concepts fit together when their relationship is not already clear.

The heading format appears in [SpecTecX #100](https://github.com/kaist-plrg/spectecx/pull/100) and [consensus-spectec #12](https://github.com/kaist-plrg/consensus-spectec/pull/12). Compact bolded bullets appear in [SpecTecX #88](https://github.com/kaist-plrg/spectecx/pull/88) and [consensus-spectec #20](https://github.com/kaist-plrg/consensus-spectec/pull/20).

<a id="c.pr-body.scope"></a>**[C.pr-body.scope](#c.pr-body.scope). Add Scope only when the affected work needs a separate overview.** Omit `## Scope` when other sections already explain the affected areas and kinds of change. Do not add it solely to supply merge-message bullets. When Scope is useful, group changes by affected area and theme. A single bullet can summarize several commits. Use `## Minor Changes` for incidental work outside the main theme.

In both sections, use `**type(scope):** Description.` for summary bullets. Choose types and scopes under [C.commit-format](#c.commit-format), capitalize descriptions, and end sentences with periods. Describe related work as a whole instead of repeating individual commit subjects. Split a bullet when no single type and scope accurately describes the work. Rename lists under a summary follow [C.commit-format.moves](#c.commit-format.moves). Use the same format within [Port and Sync scope groups](#c.ports-syncs). When these lists are present, their shared format lets the merge summary reuse the reviewed bullets without reclassifying or regrouping the work.

```markdown
## Scope

- **fix(lsp):** Checks unsaved specification files together and reports diagnostics using the editor's negotiated position encoding.

## Minor Changes

- **docs(readme):** Clarifies compiler setup instructions.
```

<a id="c.pr-body.commit-log"></a>**[C.pr-body.commit-log](#c.pr-body.commit-log). End multi-commit PR bodies with `## Commit Log` for GitHub searchability.** List final commit subjects verbatim and in order, including their `type(scope):` prefixes. Do not add backticks or hyperlinks around them. Preserve any literal characters already in a subject and keep the list synchronized with the final history.

<a id="c.pr-body.follow-ups"></a>**[C.pr-body.follow-ups](#c.pr-body.follow-ups). Separate deferred tasks from ideas and open questions under Future Work.** Use `## Future Work` when the PR has follow-ups to record. Include only subsections with content.

Under `### Deferred Tasks`, identify specific work deliberately postponed from this contribution and explain why it was postponed. These tasks are expected to be completed later and carried into the merge message under [C.deferred-work](#c.deferred-work).

Under `### Ideas and Open Questions`, describe possible improvements or open design questions without implying a commitment to pursue them. These possibilities do not belong in the merge message's `DEFERRED:` records. Select follow-up items deliberately instead of treating every possible improvement as backlog.

<a id="c.pr-body.tool-use"></a>**[C.pr-body.tool-use](#c.pr-body.tool-use). Omit routine tool-use disclaimer sections by default.** AI use alone does not require a disclosure section. Put relevant tool details with the method, source, or limitation they explain under [P.responsibility](CONTRIBUTING.md#p.responsibility).

### Ports and Syncs

<a id="c.ports-syncs"></a>

**[C.ports-syncs](#c.ports-syncs). Upstream scope groups**

*Default. Policies [P.change-scope](CONTRIBUTING.md#p.change-scope), [P.imported-work](CONTRIBUTING.md#p.imported-work), [P.source-credit](CONTRIBUTING.md#p.source-credit), [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations).*

<a id="c.ports-syncs.scope"></a>**[C.ports-syncs.scope](#c.ports-syncs.scope). Limit each Port to one upstream PR and its necessary local adaptations.** This restates [P.change-scope](CONTRIBUTING.md#p.change-scope) so reviewers can compare the original work with the local result. Independent local changes belong in another PR. A Sync may cover broader upstream changes and related local work.

<a id="c.ports-syncs.explanations"></a>**[C.ports-syncs.explanations](#c.ports-syncs.explanations). Reuse upstream explanations only when they cover the adopted design and its local assumptions.** Ports link their upstream PR in Motivation. Syncs link the comparison range or reference state being adopted.

The local PR should summarize why the work is needed here and what result it brings. Link sufficient upstream explanations instead of repeating them. Explain any missing reasoning or local design differences in the local PR.

<a id="c.ports-syncs.groups"></a>**[C.ports-syncs.groups](#c.ports-syncs.groups). Use `Ported`, `Adapted`, `Omitted`, and Sync-only `Local Changes` as upstream scope headings.** Use `###` headings within `## Scope`. Include the applicable groups and omit empty ones.

| Group | Work to describe |
| --- | --- |
| `Ported` | Upstream work taken nearly directly. |
| `Adapted` | Upstream work adjusted for the local context. |
| `Omitted` | Upstream work not taken, with the reason. |
| `Local Changes` | Related local-origin work included in a Sync. |

An omission does not by itself promise later adoption. Include it under Deferred Tasks only when its later adoption has been explicitly deferred.

<a id="c.ports-syncs.references"></a>**[C.ports-syncs.references](#c.ports-syncs.references). Use GitHub source references in upstream scope groups.** Identify origins, for example `Original: org/repo@sha`, or link a comparison range or reference file for a Sync.

## Review

<a id="c.review-labels"></a>**[C.review-labels](#c.review-labels). Label a review comment when its status could be unclear.**

*Default. Policy [P.review-blockers](CONTRIBUTING.md#p.review-blockers).*

Use `Required:`, `Suggestion:`, or `Question:` to distinguish blockers, preferences, and requests for clarification. A label is unnecessary when the status is already clear. Explain blockers under [P.review-blockers](CONTRIBUTING.md#p.review-blockers).

## Landing

### Integration defaults

<a id="c.integration"></a>**[C.integration](#c.integration). Integration defaults**

*Default. Policies [P.rules](CONTRIBUTING.md#p.rules), [P.reviewer-tasks](CONTRIBUTING.md#p.reviewer-tasks), [P.merge-method](CONTRIBUTING.md#p.merge-method).*

<a id="c.integration.rebase"></a>**[C.integration.rebase](#c.integration.rebase). Rebase onto current `main` during final integration by default.**

*Default. Principles [Coordination](PRINCIPLES.md#coordination), [Proportionality](PRINCIPLES.md#proportionality).*

Update earlier when dependencies or conflicts require it. Contributors need not rebase every open branch after each merge. Before replacing commits that dependent branches use, coordinate with affected contributors under [P.rules](CONTRIBUTING.md#p.rules). Reviewer rewrites also follow [P.reviewer-tasks](CONTRIBUTING.md#p.reviewer-tasks). Agree another integration method if rebasing would disrupt shared work.

<a id="c.integration.method"></a>**[C.integration.method](#c.integration.method). Fast-forward single-commit PRs by default.**

*Default. Policy [P.merge-method](CONTRIBUTING.md#p.merge-method).*

Count commits after final cleanup. A fast-forward avoids an extra merge commit because the single commit supplies the contribution’s permanent record.

### Single-commit records

<a id="c.single-commit-record"></a>**[C.single-commit-record](#c.single-commit-record). A single-commit PR’s message must explain the PR’s motivation, result, and scope.**

*Outline requirement. Policies [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations), [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations), [P.merge-method](CONTRIBUTING.md#p.merge-method).*

A fast-forward creates no merge message, so the commit message is the permanent landing record. Include the PR’s motivation, result, and scope, along with applicable source records.

### Merge messages

<a id="c.merge-subjects"></a>**[C.merge-subjects](#c.merge-subjects). Use `Merge: <lowercase summary> (#PR)` for merge subjects.**

*Default. Policies [P.commit-explanations](CONTRIBUTING.md#p.commit-explanations), [P.merge-method](CONTRIBUTING.md#p.merge-method).*

The summary uses the PR title with ordinary words in lowercase. Preserve proper names and acronyms. A framing paragraph explains the PR's motivation and resulting change. Summary bullets follow when useful under [C.merge-summary](#c.merge-summary).

<a id="c.merge-summary"></a>

**[C.merge-summary](#c.merge-summary). Merge-message summaries**

*Default. Policies [P.pr-explanations](CONTRIBUTING.md#p.pr-explanations), [P.merge-method](CONTRIBUTING.md#p.merge-method).*

<a id="c.merge-summary.overview"></a>**[C.merge-summary.overview](#c.merge-summary.overview). Summarize the PR as a whole.** A framing paragraph can suffice when it explains the motivation, result, and affected work. Add thematic bullets when they make the affected work easier to scan. Choose scopes for the merged result, not for each individual commit. Use `type: Description.` when a narrower scope adds no useful distinction. Commit subjects still follow [C.commit-format](#c.commit-format).

<a id="c.merge-summary.reuse"></a>**[C.merge-summary.reuse](#c.merge-summary.reuse). Reuse Scope and Minor Changes bullets when the PR includes them.** Preserve their prefixes, descriptions, grouping, and order. Remove prefix bolding and keep identifier backticks. Render Markdown links as their labels followed by URLs in parentheses. Wrap the text under [C.commit-display](#c.commit-display). When incidental work is included, separate the main and incidental work under `Changes:` and `Minor Changes:`. Otherwise, one list needs no heading. If the PR has no Scope list, write the overview under [C.merge-summary.overview](#c.merge-summary.overview).

```text
Merge: <lowercase summary> (#PR)

Framing paragraph explaining the motivation and resulting change.

Changes:
- refactor(scope): Description.

Minor Changes:
- docs(scope): Description.
```

<a id="c.merge-summary.imports"></a>**[C.merge-summary.imports](#c.merge-summary.imports). Use upstream scope groups for Port and Sync merge summaries.** Reuse the PR's groups as `Ported:`, `Adapted:`, `Omitted:`, and Sync-only `Local Changes:` in place of the main `Changes:` section. Follow the distinctions in [C.ports-syncs](#c.ports-syncs) and omit empty groups. Preserve the scoped bullets and their source references, which may use an `Original: <ref>` suffix.

<a id="c.deferred-work"></a>**[C.deferred-work](#c.deferred-work). Reserve `DEFERRED:` for work explicitly postponed from the contribution.**

*Default. Policies [P.follow-ups](CONTRIBUTING.md#p.follow-ups), [P.merge-method](CONTRIBUTING.md#p.merge-method).*

Carry only the explicitly deferred items identified in the PR's Deferred Tasks subsection or review discussion. These can include a known shortcoming accepted for this PR that should be repaired soon, or work intentionally omitted from a Port or Sync for later adoption. Ideas and Open Questions do not become deferred commitments.

Use separate bullets without a deferred-work heading. Record the unfinished task and the reason for postponing it. This keeps the searchable backlog deliberately selective.

```text
- DEFERRED: Port the omitted input forms after their dependency lands.
```

<a id="c.pr-number"></a>**[C.pr-number](#c.pr-number). Append `(#PR)` to a single-commit PR's commit subject during authorized final cleanup.**

*Default. Policies [P.final-cleanup](CONTRIBUTING.md#p.final-cleanup), [P.merge-method](CONTRIBUTING.md#p.merge-method).*

[P.merge-method](CONTRIBUTING.md#p.merge-method) requires the PR number in the permanent landing record. Appending `(#PR)` to the subject is the default format. The [workflow guide](documentation/contributing-workflow.md#landing) contains amendment and integration commands.
