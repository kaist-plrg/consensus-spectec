# Transpilation decision log

## Target and established constraints

The user identified the handwritten Capella translation as the reference and asked to start there. The translation must untangle Python fallthrough and turn possible exceptions into explicit conditions. The primary experiment uses `spec/spec_capella/` and the repository's consensus-specs pin `f96d3e7acf35125295d234da4b0c67591fdef49c` (v1.6.0). Mainnet matches the reference constants, including 32 slots per epoch and 8192 historical roots.

The saved overflow audit establishes the semantic model: definition clauses are declarative rules, interpreter backtracking does not represent Python control flow, and `otherwise` denotes a complement. Checks must occur in every rule whose source path reaches them. Failed assertions or numeric checks must not be absorbed by a fallback clause. Inline duplicated premises are an accepted convention. A new assertion construct or named condition helpers would require a separate design change.

The experiment preserves these constraints. It reuses handwritten types and interfaces, generates path conditions and inline guards from Python ASTs, and refuses unsupported operations. The eight selected bodies are inherited Phase0 helpers within Capella. They provide evidence for a first slice, not coverage of Capella-specific changes.

## Implemented mechanics

| Area | Implementation and basis |
| --- | --- |
| Fork composition | Reuse the pinned upstream builder. Require translated bodies to match Markdown ASTs and retain file and line provenance. |
| Interfaces | Generate uniform declarations from source signatures. Optional presentation overrides supply custom notation. `capella_reference.json` describes the handwritten oracle, and comparison adapters forward its interfaces to generated relations. |
| State updates | Use functional record updates and state-transforming relations from the reference. Support direct field and balance-list assignments. |
| Saved values | Capture read-only scalars, records, and sequences in fresh variables. Reject mutable root capture, writes through saved locals, and unreviewed call effects. |
| Fallthrough | Enumerate source paths, terminate at returns, and translate continuations under each branch. Preserve boolean and chained-comparison short circuiting. |
| Exceptions | Emit inline bounds, uint64 overflow/underflow, divisor, and assertion premises at reached operations. Check constants against the reference. |
| Validation | Compare Python, handwritten SpecTec, and direct generated entry points in both interpreters. All 352 comparisons pass, including 66 expected rejections. All 64 mutator adapter/direct checks pass. Source-path premise locations and reasons remain consistent with the initial guarded translation. |

## Review process

Present decisions directly to the user, one at a time, with the actual Python, handwritten SpecTec, and generated SpecTec code. Explain the behavioral or structural difference before asking. The log records the discussion and does not replace it. Unanswered questions remain open.

## Decisions

### D1. Explicit disjoint clauses (approved for now)

`is_active_validator` has one true path and two disjoint false paths. The handwritten definition has a true clause and an `otherwise` false clause. The generated version spells out the false paths. Similar expansion gives four paths for `is_slashable_validator`.

The user selected explicit disjoint clauses (option B). Individual conditions may provide finer-grained coverage, and matching the handwritten clause count is not required. Keep source paths explicit instead of combining them into generated `otherwise` clauses.

The user described the intended role of `otherwise` mainly as annotating branch completeness. How an author can annotate mutual exclusivity and completeness is deferred to a later discussion. No annotation syntax or mechanism is selected.

### D2. Retain redundant generated premises (approved)

Mechanical transpilation may retain redundant premises. It does not need to prove whether each generated guard can fail. The user assigns proving and excluding unfalsifiable coverage targets to a later test-generation stage.

Concrete examples in the generated output:

- `get_previous_epoch` checks `1 <= epoch` before subtraction, although the branch excludes genesis.
- `process_eth1_data_reset` checks epoch increment overflow, although a uint64 slot divided by 32 bounds the current epoch.
- `get_block_root_at_slot` checks the root-vector index, although the SSZ vector length and modulo guarantee its range. The target type represents the vector as an unrestricted sequence.

The prototype retains these guards. It already deduplicates identical premise text and omits divisor checks for verified positive constants. There is no general implication or reachability analysis in the lowerer.

The agreed direction is shared analysis on typed SpecTec, consumed by optional output simplification and test generation. Mechanical lowering preserves guards. General simplification may use assumptions established by the specification itself. Test generation may use additional campaign-specific assumptions, which do not justify changing the general specification. The analysis algorithm and implementation are not selected.

Later coverage analysis must distinguish proven unfalsifiability from an unsuccessful search. Any proof must record the applicable type, path, and input assumptions. Solver timeouts or unknown results do not justify excluding a target.

### D3. Uniform interfaces with optional author overrides (approved for now)

Python `increase_balance` maps to `IncreaseBalance` with infix balance-update notation. Pure helpers remain functions. Python `index` becomes SpecTec `vid`.

The user selected option B: generate a uniform interface by default and allow author overrides for custom notation. New functions should not require hand-authored notation before their bodies can be translated. Comparing uniform interfaces with the handwritten reference requires adapting calls in the comparison harness.

The prototype implements this default for the eight selected definitions. `--presentation-overrides` supplies explicit JSON overrides for argument names, mutator relation names, and positional notation. The handwritten mapping is oracle-only metadata. Namespaced generated mutator relations and forwarding rules adapt the interfaces for comparison without copying guards or computations. This decision covers interface presentation. It does not settle alias handling, effect analysis, or helper decomposition.

### D4. Keep complete source paths inline (approved for now)

The user selected option A for a conditional followed by shared code: split the caller into complete paths, duplicating the continuation. The generator must not automatically extract value-producing helpers at these joins. Helper extraction is deferred. This concerns computational helper boundaries, independently of the presentation adapters needed to compare different interfaces under D3.

The exit-queue increment in `initiate_validator_exit` is the concrete example. Its handwritten counterpart extracts `$select_epoch_exit_queue`. The approved initial strategy instead keeps increment and no-increment paths in the caller, with explicit disjoint conditions and the shared update on each path.

Writable references and loop lowering remain separate open questions. `initiate_validator_exit` binds `validator = state.validators[index]` before mutating its fields. Treating this as an independent value loses the state update. `process_registry_updates` and `process_effective_balance_updates` also require iteration and state-dependent updates. These constructs currently stop translation. Read-only saved values are covered by D8. The full `initiate_validator_exit` function has no generated SpecTec yet. D4 does not authorize a writable-reference or loop policy.

### D5. What should happen when Python and the handwritten reference disagree?

The current slice has no observed disagreements on its cases. Extra guards and different clause layouts show that matching behavior and matching presentation are distinct goals.

Recommendation: report a minimal counterexample with source locations and stop translation of that definition. The user can choose a reference correction, source-version adjustment, or explicit modeling boundary. Do not silently repair either specification to make comparisons pass.

### D6. What validation is required before expanding the claim?

The verifier compares returned values, rejection, and supplied state fields against real Python SSZ objects. It compares full outputs between the SpecTec variants. Untouched SpecTec fields have fixture defaults, error-class fidelity is not checked, and official state-transition vectors have not been run.

The complete handwritten corpus first fails structuring in `$get_domain`, whose omitted-epoch and supplied-epoch cases each have an `otherwise` clause (`05-helpers-domain-fork.spectec`, lines 36 and 44). The structuring pass rejects multiple otherwise paths in one function. A scratch investigation also encounters a further structuring assertion after bypassing this function, so this is not the only integration limitation. Selected dependency slices pass parsing, elaboration, structuring, IL, and SL. Full-corpus validation requires resolving these existing integration issues and using complete state fixtures. Recommendation: retain the selected-definition claim and make a real mutating operation with complete fixtures the next validation milestone.

### D7. Observe successful results and rejection (approved)

The translation preserves returned values and final state on success, and rejection on failure. Python's partially modified state after an exception is outside the observation boundary. The generated specification represents successful transitions guarded by premises. It does not return a partial state on failure or claim that Python rolls back earlier mutations.

The concrete source example is `initiate_validator_exit`. Its first assignment updates `validator.exit_epoch`. Its second assignment can overflow while computing `validator.withdrawable_epoch`. Running the pinned Capella Python with a target validator at `FAR_FUTURE_EPOCH` and a second validator at `UINT64_MAX - 1` confirms that rejection leaves the target's exit epoch changed to `UINT64_MAX - 1`, while its previous withdrawable epoch remains unchanged. This is an SSZ-typed boundary case, not a claim of protocol reachability. The handwritten relation has an overflow premise and no successful output for this case. The full function is not generated yet.

The comparison harness checks successful values and rejection status. Exception classes and messages are not equality criteria. Exception recovery and callers that observe state after rejection are outside this contract. Source paths that return before an operation must bypass its guards. A failed guard cannot select another successful clause. Writable reference support and loop lowering remain separate decisions.

### D8. Support read-only saved values (approved)

The user approved saved values after reviewing `weigh_justification_and_finalization`, inherited by Capella from Phase0. The function saves `old_current_justified_checkpoint = state.current_justified_checkpoint`, replaces the state field during justification, then reads the saved checkpoint during finalization. Re-reading the updated field would change the finalization condition and result. The handwritten `WeighJustificationAndFinalization/justify_cur_finalize_cur` rule captures the input field as `checkpoint_cur` and uses that variable after the update.

Local assignments bind values to fresh SpecTec variables. Captured records and sequences retain their old contents after independent state updates. Read-only local copies and uses across branches are supported. This follows the pinned SSZ runtime's child-view behavior, which retains each view's backing when a separately obtained view or its parent is updated.

The mutable root is different: `saved = state` preserves the same Python object and is rejected. Writes through saved child views can invoke hooks that update the parent state, so those writes are also rejected. Passing a saved value to a helper requires a reviewed read-only effect contract. A return type alone does not establish that contract.

Regression fixtures compare saved checkpoints, sequences, indexed records, branch continuations, and pure helper calls against actual pinned Python execution and both SpecTec interpreters. They also check rejection of unsupported writes and unreviewed helper effects. These fixtures isolate the approved behavior. The full justification/finalization function still requires additional lowering support.

## Gloas follow-on

The separate Gloas candidate is v1.7.0-beta.1 at `477321355d48d527e7e1e4d572f6a40a0b41072a`. The user accepted that candidate before selecting Capella as the starting reference. Its scalar experiment is separate evidence. Applying the reference-guided translation to Gloas requires reviewing new types, state fields, operations, and external contracts after the Capella rules are established.
