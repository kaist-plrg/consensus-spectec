# Consensus SpecTec Transpiler: Automating SpecTec Authoring and Maintenance for Ethereum Consensus Specifications

## 1. Project Overview

### Title

**Consensus SpecTec Transpiler: Automating SpecTec Authoring and Maintenance for Ethereum Consensus Specifications**

### Objective

This project is a follow-up to the recent work on **SpecTrum: Specification-Guided Differential Fuzzing for Ethereum Consensus Clients** [1], which demonstrated that mechanizing the Ethereum consensus specification in SpecTec can expose semantic coverage gaps and uncover cross-client divergences that conventional testing may miss.

The underlying SpecTec approach predates SpecTrum and has already been applied to other real-world specifications, including WebAssembly through Wasm-SpecTec [2, 3], P4 through P4-SpecTec [4, 5], and related mechanized specification work for JavaScript/ECMAScript [6, 7]. Together with SpecTrum, these works demonstrate the practical value of executable and mechanized specifications for specification validation, testing, and bug discovery.

The remaining challenge is **maintaining Consensus-SpecTec as the Ethereum consensus specification evolves**. Ethereum specifications are already organized incrementally: each fork builds on the previous fork and specifies its changes. Consensus-SpecTec can similarly be extended using fork differences rather than being rewritten from scratch. However, those changes still need to be manually identified, translated into SpecTec, reviewed, and kept synchronized with the Python consensus specification.

This direction is distinct from the **MiniZinc-based model test generation** currently used in `consensus-specs` [8], which Nikos Baxevanis (nikos.baxevanis@ethereum.org) pointed me to during our discussion. MiniZinc focuses on generating concrete consensus test instances from manually defined constraints, whereas this project addresses an upstream problem: systematically translating and maintaining the mechanized specification itself. The approaches are therefore complementary.

Following discussions with **Prof. Sukyoung Ryu, other authors and researchers involved in SpecTrum, and Youngjoon Song from Offchain Labs**, we have been exploring this follow-up direction for approximately two weeks. As a preliminary experiment, we have been using AI to assist implementation and to explore translation patterns between the Python consensus specification and existing Consensus-SpecTec definitions, using Capella as an initial reference as in the SpecTrum work.

AI is only being used to accelerate this exploratory implementation work. **The intended final deliverable is a mechanical and deterministic transpiler whose translation process does not depend on AI inference.*

I previously worked with the **Ethereum Foundation Protocol Security Research Team**, and I proposed this direction to **Nikos Baxevanis** (nikos.baxevanis@ethereum.org) and **Fredrik Svantes** (fredrik.svantes@ethereum.org) as infrastructure that could support ongoing mainnet and fork-security work. After subsequent discussions, I was invited to develop the idea further as a grant proposal. We are also considering the possibility of developing the results into a **follow-up research publication**, depending on the technical results of the project.

---

## 2. Existing Work and Remaining Problem

### 2.1 Consensus-SpecTec and SpecTrum

SpecTrum introduced **Consensus-SpecTec**, a mechanized representation of the Ethereum consensus specification that makes specification-level validity conditions explicit.

Using this representation, SpecTrum introduced **premise coverage**, which measures whether individual specification premises are exercised as both true and false by existing tests, and used uncovered premises to guide differential fuzzing.

The work demonstrated that this information can expose behaviors that ordinary implementation-level code coverage does not capture. In its evaluation across five Ethereum consensus clients, SpecTrum reported cross-client divergence cases that depended on premises exposed through the mechanized specification [1].

This establishes the main premise behind the proposed project:

> **Maintaining an executable specification-level representation of Ethereum consensus provides practical value for testing and security analysis.**

### 2.2 Incremental Fork Maintenance

The problem is not that the entire Consensus-SpecTec specification must be recreated whenever Ethereum introduces a new fork.

Both Ethereum's Python consensus specification and the SpecTrum approach are naturally incremental. A later fork can be represented in terms of the changes it introduces relative to its predecessor.

However, when a new fork introduces additional consensus rules, the corresponding processes described in SpecTrum still need to be manually applied to those newly introduced rules in Consensus-SpecTec.

As Ethereum continues evolving, this translation and synchronization process becomes a recurring maintenance task.

The proposed transpiler targets this specific problem.

### 2.3 Relationship to MiniZinc

The existing `consensus-specs` repository also contains model-based fork-choice test generation using MiniZinc [8].

For example, MiniZinc models are used to construct constrained super-majority links, block trees, and fork-choice states satisfying particular predicate combinations.

This addresses a different problem from the proposed transpiler.

MiniZinc can be viewed primarily as answering:

> Given a set of manually encoded constraints, what concrete test instances satisfy them?

The Consensus SpecTec Transpiler instead addresses:

> Given the Ethereum consensus specification, how can its supported semantics be systematically translated into and maintained as Consensus-SpecTec?

The transpiler therefore does not replace MiniZinc or existing consensus tests. It provides specification-maintenance infrastructure that can support downstream testing techniques such as those explored by SpecTrum.

---

## 3. Proposed Work: Consensus SpecTec Transpiler

The main deliverable of this project is **a deterministic transpiler that translates supported parts of the Ethereum Python consensus specification into Consensus-SpecTec**.

AI is currently being used only as an implementation aid during the preliminary development stage, for example to accelerate exploration of translation patterns and prototype implementation. **AI will not be part of the final transpilation process.** The final deliverable will be a mechanical and deterministic transpiler that performs the translation without AI inference and produces reproducible results for the same input specification.

### 3.1 Input and Output

The input is the Python consensus specification maintained in `ethereum/consensus-specs`, including the additions and modifications introduced by each fork within the subset supported by the transpiler.

The output is the corresponding **Consensus-SpecTec definitions**, suitable for use with the existing Consensus-SpecTec tooling.

### 3.2 Initial Scope and Fork Progression

The initial development will use **Capella and Deneb** as reference specifications because manually written Consensus-SpecTec definitions are already available for comparison and validation.

Once the transpiler has been established and validated against these reference cases, **the same transpiler** will be applied to subsequent Ethereum consensus forks, including **Electra**, **Fulu**, and **Gloas**.

The purpose is not to build a separate transpiler for each fork. Rather, the transpiler is intended to operate across the evolving `consensus-specs` codebase and translate fork-specific additions and modifications using a common set of translation rules.

If a future fork introduces specification constructs that are not covered by the existing translation rules, the transpiler can be extended to support those constructs while preserving the same overall translation workflow.

The long-term goal is therefore for a single reusable transpiler to continue supporting future **Ethereum consensus forks** as the specification evolves.

---

## 4. Project Plan and Milestones

---

## 5. Deliverables and Evaluation

The primary deliverable of this project is a **reusable and deterministic Consensus SpecTec transpiler** that translates supported parts of the Ethereum Python consensus specification into Consensus-SpecTec.

### 5.1 Primary Deliverables

#### 1. Consensus SpecTec Transpiler

A deterministic transpiler that converts supported parts of the Python consensus specification into corresponding Consensus-SpecTec definitions.

The goal is to build a single reusable transpiler rather than separate translation tooling for individual forks.

#### 2. Validation Using Existing Consensus-SpecTec

**Capella and Deneb** will be used as reference specifications because manually written Consensus-SpecTec definitions are already available.

These existing definitions will provide a basis for evaluating and improving the transpiler during development.

#### 3. Application to Later Forks

After development and validation using Capella and Deneb, the same transpiler will be applied to subsequent Ethereum consensus specifications:

**Deneb -> Electra -> Fulu -> Gloas -> Future Forks**

The objective is to confirm that the transpiler can continue to operate as the consensus specification evolves, rather than requiring a separate translation process for each fork.

The same approach is intended to remain applicable to subsequent Ethereum consensus forks.

#### 4. Documentation

The project will document the transpiler, its supported translation scope, and the process required to maintain and extend it as the Ethereum consensus specification evolves.

### 5.2 Evaluation

The project will primarily evaluate whether the transpiler can:

- generate Consensus-SpecTec from the supported parts of the Python consensus specification
- reproduce the relevant Consensus-SpecTec definitions available for Capella and Deneb and
- remain reusable when applied to subsequent forks such as Electra, Fulu, and Gloas.

The main evaluation goal is to determine whether a **single transpiler can be maintained and reused across successive Ethereum consensus forks**.

---

## 6. Expected Impact and Long-Term Sustainability

SpecTrum demonstrated that Consensus-SpecTec can provide useful specification-level information for Ethereum consensus testing and differential fuzzing.

The purpose of this project is to make that approach easier to maintain as the Ethereum consensus specification continues to evolve.

By replacing part of the manual SpecTec authoring process with a reusable transpiler, the project aims to reduce the effort required to keep Consensus-SpecTec aligned with successive protocol upgrades.

The intended workflow is:

```
Ethereum consensus specification
            ↓
Consensus SpecTec Transpiler
            ↓
Consensus-SpecTec
            ↓
Existing SpecTrum testing workflow
```

---

## 7. Timeline and Budget

---

## 8. References

[1] SpecTrum: Specification-Guided Differential Fuzzing for Ethereum Consensus Clients
https://arxiv.org/abs/2608.17738

[2] Bringing the WebAssembly Standard up to Speed with SpecTec (Wasm-SpecTec)
https://doi.org/10.1145/3656440

[3] Wasm SpecTec specification tools
https://github.com/Wasm-DSL/spectec/tree/main

[4] P4-SpecTec: Integrating a Language Mechanization Framework into the Real-World P4 Specification
https://arxiv.org/abs/2608.00639

[5] Mechanization toolchain for the P4 programming language
https://github.com/kaist-plrg/p4-spectec

[6] JavaScript Language Design and Implementation in Tandem
https://cacm.acm.org/research/javascript-language-design-and-implementation-in-tandem/

[7] ECMAScript Specification (ECMA-262) Metalanguage
https://github.com/kaist-plrg/esmeta

[8] MiniZinc in Ethereum Consensus Specification
https://github.com/ethereum/consensus-specs/tree/master/tests/generators/compliance_runners/fork_choice