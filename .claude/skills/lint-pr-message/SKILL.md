---
name: lint-pr-message
description: Lint commit messages and the PR title and description before opening or updating a PR. Use before `git push` of a PR branch, `gh pr create`, or `gh pr edit`.
---

# Lint PR messages

Run this before submitting a PR, and again before pushing amended commits
or editing a PR description. Check every commit in `origin/main..HEAD`
and the PR title and description. Fix the messages before submitting
rather than leaving them for review.

## Collect the messages

```sh
git log --format='%H%n%B%n---' origin/main..HEAD
```

## Mechanical checks

```sh
git log --format=%B origin/main..HEAD | awk 'length > 72 { print "too long: " $0 }'
```

- Wrap the subject and body to 72 columns. Long URLs and trailers such as
  `Fixes:` may exceed it.
- Separate the subject from the body with one blank line.
- No trailing period on the subject.

## Subject

Format: `type(scope): summary`, for example
`fix(spec): clamp the activation-queue slice to the queue length`.

- `type` is one of `feat`, `fix`, `refactor`, `test`, `ci`, `docs`,
  `style`, `chore`. `scope` is optional and names the affected area, such
  as `spec`, `targets/ethereum`, or `contributing`.
- Write the summary in lowercase imperative mood: "skip", "add", "check".
- State the condition or effect precisely and drop redundant words.
  "skip CI run for markdown changes" becomes
  "skip CI for Markdown-only changes".

## Body

Use the past-tense motivation, then present-tense solution pattern:

1. **Motivation paragraph, past tense.** Describe the prior state or
   problem as it was. "CI ran for Markdown-only changes even when they did
   not affect code." Past tense lets a reader tell the prior state from
   the new one at a glance.
2. **Solution paragraph, present tense, third-person verb.** Start with
   what the commit does: "Adds", "Skips", "Moves", "Marks". Describe the
   result, not the editing process.

Then check the wording:

- Keep motivation and solution in separate paragraphs.
- Replace vague phrases ("the actual codebase change", "some issues")
  with the concrete thing.
- Remove asides about possible future work, especially parentheticals
  inside the motivation. Mention follow-up work only if the change
  depends on it, in its own sentence.
- Wrap identifiers, file names, extensions, commands, and flags in
  backticks: `.md`, `check_spec_tests.py`, `--output`, `$take_prefix_<X>`.
- Say what was verified or what scope was left out when a reviewer needs
  it. Do not pad with restatements of the diff.
- For regressions, add `Fixes: <12-char sha> ("<subject>")` trailers.
  Reference issues with `Closes #N.` on its own line.

## PR title and description

- A single-commit PR uses the commit subject as its title and the commit
  body as its description, verbatim. No `### Motivation` headings.
- A multi-commit PR uses a summary title. The description opens with a
  motivation-then-solution paragraph, then lists each commit as
  `- type(scope): <present-tense summary>`, then any `Closes #N.` line.
  This text becomes the `Merge: <title> (#N)` commit body.
- Keep the PR to one topic. Name incidental changes separately.

## Example

Before:

```
ci: skip CI run for markdown changes

Running CI should only gate the actual codebase change, not for documentation change (unless we add CI check for grammar of our documentation). CI now doesn't run when only md files are changed.
```

After:

```
ci: skip CI for Markdown-only changes

CI ran for Markdown-only changes even when they did not affect code.

Skips CI when only `.md` files change.
```

## Report

List each problem with the commit or PR field it appears in and the
proposed rewrite. Apply the rewrites when asked to submit; otherwise show
them and wait. Amending pushed commits requires a force push, so confirm
first if anyone else uses the branch.
