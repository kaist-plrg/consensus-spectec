# Consensus SpecTec Transpiler: Automating SpecTec Authoring and Maintenance for Ethereum Consensus Specifications

## 1. Project Overview

Building on **SpecTrum: Specification-Guided Differential Fuzzing for Ethereum Consensus Clients** [1], this project will develop a deterministic transpiler for keeping Consensus-SpecTec aligned with Ethereum's Python consensus specification as forks evolve. SpecTrum demonstrated that mechanizing the consensus specification can expose semantic coverage gaps and cross-client divergences that conventional testing may miss.

Ethereum specifications are organized incrementally: each fork builds on the previous fork and specifies its changes. Consensus-SpecTec can likewise be extended using fork differences, but those changes still need to be translated into SpecTec, reviewed, and checked against the Python source. The proposed transpiler will automate that translation, reducing the manual effort needed for each fork.

Our team includes Prof. Sukyoung Ryu and Seokhun Jeong, coauthors of SpecTrum, and Youngjun Song from Offchain. We have begun exploring translation from the Python consensus specification to Consensus-SpecTec, using Capella as an initial reference and AI to assist implementation. The delivered transpiler will translate mechanically and deterministically, without AI involvement.

I previously worked with the **Ethereum Foundation Protocol Security Research Team**, and I proposed this direction to **Nikos Baxevanis** (nikos.baxevanis@ethereum.org) and **Fredrik Svantes** (fredrik.svantes@ethereum.org) as infrastructure that could support ongoing mainnet and fork-security work. After subsequent discussions, I was invited to develop the idea further as a grant proposal. We are also considering the possibility of developing the results into a **follow-up research publication**, depending on the technical results of the project.

---

## 2. Existing Work and Remaining Problem

### 2.1 Mechanized Specifications and SpecTrum

Mechanized specifications predate SpecTrum. ESMeta extracts an executable representation of the ECMAScript specification [3, 4]. Wasm-SpecTec uses the SpecTec language to mechanize the WebAssembly specification [5, 6], and P4-SpecTec applies the same framework to P4's static and dynamic semantics [7, 8].

SpecTrum applies SpecTec to the Ethereum consensus specification through **Consensus-SpecTec**, a mechanized representation that makes validity conditions explicit [1]. Using this representation, SpecTrum introduced **premise coverage**, which measures whether individual specification premises are exercised as both true and false by existing tests, and used uncovered premises to guide differential fuzzing.

The work demonstrated that this information can expose behaviors that ordinary implementation-level code coverage does not capture. In its evaluation across five Ethereum consensus clients, SpecTrum reported cross-client divergence cases that depended on premises exposed through the mechanized specification [1].

The remaining maintenance task is translating each fork's new or modified Python rules into Consensus-SpecTec and checking the resulting definitions against the source.

### 2.2 MiniZinc and SpecTrum Test Generation

MiniZinc-based test generation and SpecTrum pursue the same goal: tests that exercise each validity condition of a state-transition function as both satisfied and violated. A validity condition is a check that makes a function reject its input, most often an `assert` statement in the Python specification. The `consensus-specs` repository applies MiniZinc first to fork choice [2] and, in an open pull request, to Gloas state-transition functions, including block operations and epoch-processing steps [9]. For each function, the test authors write a model of its validity conditions, and a constraint solver generates inputs that satisfy all of them as well as inputs that violate exactly one, so that each rejection has a single cause.

SpecTrum instead derives its test targets from Consensus-SpecTec, an executable SpecTec representation of the specification [1]. Each validity condition appears as a premise of a SpecTec rule. SpecTrum measures which premises existing tests have not exercised as both satisfied and violated, and directs differential fuzzing across consensus clients toward them.

The main advantage of Consensus-SpecTec over a model-based approach is that it can be executed and tested against the original specification. Running Consensus-SpecTec and the Python specification on the same inputs and comparing their results checks whether the representation is faithful to its source. A MiniZinc model, by contrast, abstracts only the conditions its authors select. The tests it generates are checked against the Python specification, but the model itself cannot be run on arbitrary inputs, so a condition missing from the model goes unnoticed.

Consensus-SpecTec also represents every validity condition, including those that the Python code never writes as an `assert`, and comparing the two approaches on the same operations makes this difference visible. Four block operations that have existed since Capella reject a validator index that does not exist in the registry: `process_bls_to_execution_change`, `process_voluntary_exit`, `process_proposer_slashing`, and `process_attester_slashing`. Only `process_bls_to_execution_change` checks the index with an `assert`, and only its MiniZinc model generates a nonexistent index. The other three fail implicitly when they read `state.validators` at that index, and their MiniZinc models always select an existing validator, although the hand-written tests in `consensus-specs` include this case. The Capella definitions of Consensus-SpecTec state the index check as a premise in all four operations.

In addition, the proposed transpiler would derive Consensus-SpecTec automatically from the Python specification, whereas MiniZinc models are written by hand for each function. A hand-written model covers only the conditions its authors identify and must be revised whenever the specification changes or a new fork is added. The current Consensus-SpecTec definitions are also written by hand. The transpiler would replace this manual step: it would turn every failure point in the Python code into a premise and regenerate the definitions for each fork, and the behavioral-equivalence evaluation in Section 5.2 would check the generated definitions against the Python specification.

---

## 3. Proposed Work: Consensus SpecTec Transpiler

One deterministic transpiler will translate the executable Python state-transition specification through Gloas into Consensus-SpecTec.

### 3.1 Translation Requirements

The input to the transpiler is the Python consensus specification maintained in `ethereum/consensus-specs`, including the additions and modifications introduced by each target fork.

The output is the corresponding **Consensus-SpecTec definitions**, suitable for use with the existing Consensus-SpecTec tooling. These definitions must preserve the Python specification's returned values and resulting state on successful executions. Conditions that make the Python execution fail must appear as explicit premises that reject the corresponding input in SpecTec. The transpiler does not plan to reproduce Python exception messages or partially modified state after failure.

A companion linter will report unsupported Python syntax and operations with their source locations. Unsupported constructs must be rejected rather than silently translated into inaccurate SpecTec definitions.

### 3.2 Coverage and Fork Progression

Development starts with **Capella and Deneb**, whose handwritten Consensus-SpecTec definitions provide reference behavior, then applies the same translation rules through **Electra, Fulu, and Gloas**. The project will pin the upstream revision used for each fork. The grant deliverable covers every Python construct required by the complete executable state-transition specification through Gloas. Any unsupported construct within that scope must be resolved before release.

Later forks can use the same toolchain, as long as they use Python constructs supported by the transpiler. The linter will identify unsupported Python syntax or operations that require extensions to the translation rules.

---

## 4. Project Plan and Milestones

1. **Capella proof of concept:** Use the Python Capella specification and handwritten Consensus-SpecTec definitions as references to implement an initial transpiler. Differentially test its generated definitions against the Python source. Milestone: a working Capella prototype with comparison results.
2. **Incremental fork coverage:** Complete the Capella translation, then extend the same transpiler through Deneb, Electra, Fulu, and Gloas, resolving unsupported constructs and differentially testing each pinned fork. Milestone: generated definitions for the complete state-transition specification through Gloas.
3. **Compatibility and release:** Add the compatibility linter, check each pinned fork for incompatible constructs, and document the translation rules, source revisions, and known limitations. Milestone: released tools, evaluation results, and documentation.

---

## 5. Deliverables and Evaluation

### 5.1 Primary Deliverables

1. **Consensus SpecTec Transpiler:** A deterministic tool that generates executable Consensus-SpecTec definitions for the complete state-transition specification through Gloas.
2. **Transpiler compatibility linter:** A tool that checks the Python consensus specification against the transpiler's translation rules and reports the source location and reason for any incompatible construct.
3. **Documentation** of the translation rules, pinned consensus-spec versions, and known limitations.

### 5.2 Evaluation

1. **Compatibility:** Run both tools on each pinned fork from Capella through Gloas. Transpilation must be successful, and the linter must report no incompatibilities.
2. **Behavioral equivalence:** Differential test the generated Consensus-SpecTec definitions against the corresponding Python specifications on the same inputs, comparing returned values and resulting states and checking that Python failure conditions correspond to explicit SpecTec rejection premises. Handwritten Capella and Deneb definitions from SpecTrum serve as additional references.

---

## 6. Expected Impact and Future Work

SpecTrum demonstrated that Consensus-SpecTec can provide useful specification-level information for Ethereum consensus testing and differential fuzzing.

By generating Consensus-SpecTec from the Python specification, the transpiler reduces the manual effort of keeping that representation aligned with protocol changes. Its output can feed the existing SpecTrum testing workflow:

```
Ethereum consensus specification
            ↓
Consensus SpecTec Transpiler
            ↓
Consensus-SpecTec
            ↓
Existing SpecTrum testing workflow
```

Support for forks after Gloas and later EIP-driven changes may be explored in the future. The compatibility linter can identify unsupported constructs, but the extensions would need implementation and evaluation.

---

## 7. Timeline and Budget

---

## 8. References

[1] SpecTrum: Specification-Guided Differential Fuzzing for Ethereum Consensus Clients
https://arxiv.org/abs/2608.17738

[2] MiniZinc in Ethereum Consensus Specification
https://github.com/ethereum/consensus-specs/tree/master/tests/generators/compliance_runners/fork_choice

[3] JavaScript Language Design and Implementation in Tandem
https://cacm.acm.org/research/javascript-language-design-and-implementation-in-tandem/

[4] ECMAScript Specification (ECMA-262) Metalanguage
https://github.com/kaist-plrg/esmeta

[5] Bringing the WebAssembly Standard up to Speed with SpecTec (Wasm-SpecTec)
https://doi.org/10.1145/3656440

[6] Wasm SpecTec specification tools
https://github.com/Wasm-DSL/spectec/tree/main

[7] P4-SpecTec: Integrating a Language Mechanization Framework into the Real-World P4 Specification
https://arxiv.org/abs/2608.00639

[8] Mechanization toolchain for the P4 programming language
https://github.com/kaist-plrg/p4-spectec

[9] Gloas state-transition compliance test generator (open pull request, revision 8cb10666)
https://github.com/ethereum/consensus-specs/pull/5573