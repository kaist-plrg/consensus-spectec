# Consensus SpecTec Transpiler: Automating SpecTec Authoring and Maintenance for Ethereum Consensus Specifications

## 1. Project Overview

## Title

Consensus SpecTec Transpiler: Automating SpecTec Authoring and Maintenance for Ethereum Consensus Specifications

## Objective

This project is a follow-up to the recent work on **SpecTrum: Specification-Guided Differential Testing for Ethereum Consensus Clients** [1], which demonstrated that mechanizing the Ethereum consensus specification in SpecTec can expose semantic coverage gaps and uncover cross-client divergences that conventional testing may miss.

The underlying SpecTec approach itself predates SpecTrum and has already been applied to other real-world specifications, including WebAssembly through Wasm-SpecTec [2, 3], P4 through P4-SpecTec [4, 5], and related mechanized specification work for JavaScript/ECMAScript [6, 7]. Together with the results of SpecTrum, these works provide evidence that executable and mechanized specifications can be practically useful for specification validation, testing, and bug discovery.

The remaining problem is **maintenance cost**. Ethereum continues to evolve through new forks and EIPs, while the current Consensus-SpecTec representation requires substantial manual effort to construct and keep synchronized with the Python consensus specification. The goal of this project is therefore to develop a **proper transpiler from the Ethereum consensus specification to SpecTec**, so that Consensus-SpecTec can be updated and maintained across **Gloas and future forks/EIPs with significantly lower recurring manual cost**.

This direction is distinct from the **MiniZinc-based model test generation** currently used in `consensus-specs`, which Nikos Baxevanis(nikos.baxevanis@ethereum.org) pointed me to during our discussion. MiniZinc focuses on generating concrete consensus test instances from manually defined constraints, whereas this project addresses the upstream problem of **systematically producing and maintaining the mechanized specification itself**. The two approaches are therefore complementary rather than replacements for one another.

Following discussions with **Prof. Sukyoung Ryu, other authors and researchers involved in SpecTrum**, and Youngjoon Song from Offchain Labs, we have been exploring this follow-up direction for approximately two weeks. As an initial experiment, we are currently conducting simple AI-based translation tests from the existing Python consensus specification into SpecTec, using Capella as the reference target, as in the SpecTrum paper. The objective of this grant is to develop this preliminary work into a proper and maintainable transpiler.

I previously worked with the **Ethereum Foundation Protocol Security Research Team**, and I proposed this direction to **Nikos Baxevanis** (nikos.baxevanis@ethereum.org) and **Fredrik Svantes** (fredrik.svantes@ethereum.org) as infrastructure that could support ongoing mainnet and fork-security work. After subsequent discussions, I was invited to develop the idea further as a grant proposal. We are also considering the possibility of developing the results into a **follow-up research publication**, depending on the technical results of the project.

### References
[1] SpecTrum: Specification-Guided Differential Testing for Ethereum Consensus Clients
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

## 2. Why This Project Matters / Expected Impact

SpecTrum has already demonstrated that representing the Ethereum consensus specification in SpecTec can provide security value beyond conventional code coverage and manually written test cases. By making specification-level premises explicit, it becomes possible to identify semantic conditions that existing tests do not exercise and to use those gaps to guide further differential testing and bug discovery.

The main limitation is that this benefit is currently expensive to maintain.

Ethereum is not a static protocol. New forks and EIPs continuously modify state-transition logic, validation conditions, data structures, constants, and other consensus rules. If Consensus-SpecTec must be manually updated whenever the Python consensus specification changes, much of the cost of the original mechanization has to be paid repeatedly for every major protocol update.

The importance of this project is therefore not simply that it can generate SpecTec code. Its larger goal is to make the security benefits demonstrated by SpecTrum **sustainable** as **Ethereum continues to evolve**.

A successful transpiler would reduce the recurring cost of maintaining Consensus-SpecTec and allow researchers to spend less time manually reconstructing specification logic and more time reviewing meaningful semantic changes, identifying insufficiently tested protocol paths, and performing security analysis.

This could establish a continuous workflow in which changes to the Ethereum consensus specification can be reflected in Consensus-SpecTec with substantially less manual effort, making specification-level coverage practical not only for Capella or a single research experiment, but also for **Gloas, future forks, and individual EIPs**.

The expected impact is particularly relevant to Ethereum protocol security in several areas:

- Fork security: Newly introduced protocol rules can be analyzed at the specification level to determine which semantic conditions are or are not exercised by existing tests.
- Testing and fuzzing: Uncovered specification paths can provide concrete targets for additional test generation, differential testing, and fuzzing.
- Regression detection: Maintaining a synchronized mechanized specification can make it easier to detect unintended behavioral changes as the protocol evolves.
- Lower long-term maintenance cost: Instead of repeatedly rebuilding SpecTec specifications manually, the transpiler can make future updates incremental and reusable.
- Research infrastructure: The resulting transpiler and maintained Consensus-SpecTec can support further work in specification-guided testing, specification-based test generation, formal analysis, and future research built on SpecTrum.

The project therefore aims to convert the result of SpecTrum from a successful but largely manually maintained research artifact into reusable infrastructure for continuous Ethereum protocol security work.

If successful, the value of the project compounds over time: each new fork or EIP would not require starting the mechanization process again from the beginning, and the cost of keeping specification-level security analysis aligned with Ethereum development could be significantly reduced.

# 3. Differentiation and Contribution

This project is not intended to replace existing Ethereum consensus testing infrastructure. Its contribution is to address a different layer of the problem: **the cost of creating and continuously maintaining the mechanized specification that specification-level testing depends on**.

Existing approaches already provide valuable capabilities at different stages of the testing process.

The Python `consensus-specs` repository serves as the primary executable specification and test-definition environment for Ethereum consensus development. MiniZinc-based tooling can generate concrete consensus states satisfying manually defined constraints. SpecTrum has demonstrated that a SpecTec representation can expose specification-level coverage gaps and guide differential testing across clients.

However, these approaches do not solve the problem of **keeping Consensus-SpecTec synchronized with a continuously changing Ethereum specification**.

At present, producing a SpecTec representation still requires substantial manual interpretation and rewriting of the original specification. This creates a maintenance bottleneck whenever protocol logic changes across forks or through new EIPs.

The proposed transpiler specifically targets this missing layer.

Its primary contributions are expected to be:

## 3.1. Reducing the recurring cost of Consensus-SpecTec maintenance

Instead of treating each fork as a new manual mechanization task, the transpiler aims to make updates from the Python consensus specification reusable and systematic.

The objective is not only to reduce the cost of producing the initial SpecTec representation, but also to reduce the cost of maintaining it over the lifetime of the protocol.

## 3.2 Making SpecTrum-style analysis sustainable across future forks

SpecTrum demonstrated the effectiveness of specification-level premise coverage and specification-guided differential testing.

Without a scalable way to maintain the underlying SpecTec specification, however, extending the same methodology to every future fork becomes increasingly expensive.

The transpiler is intended to make this analysis practical beyond the original research target and allow it to follow Ethereum protocol development continuously.

## 3.3. Connecting specification changes more directly to security testing

A maintained Consensus-SpecTec representation can provide a bridge between changes in the protocol specification and downstream security work.

When a new fork or EIP introduces new behavior, the corresponding specification changes can eventually be reflected into:

- premise coverage analysis,
- targeted test generation,
- differential testing,
- fuzzing,
- specification-based testing,
- and other specification-driven security analysis.

This allows testing effort to focus more directly on new or insufficiently exercised protocol semantics, rather than relying only on implementation-level coverage.

## 3.4. Complementing existing model-based test generation

MiniZinc and similar constraint-solving approaches remain useful for generating concrete protocol states and test instances.

The transpiler addresses the upstream problem of maintaining the semantic specification itself.

If successful, the two approaches can become complementary components of a broader testing workflow, where mechanized specification information helps identify meaningful semantic conditions and specification-based generation helps construct concrete states that exercise them.

## 3.5. Creating reusable infrastructure rather than a one-time research artifact

The intended output is not only a reconstructed version of Capella in SpecTec.

The larger contribution is a reusable tool that can continue to support Gloas, later forks, and individual EIPs, while reducing the amount of repeated manual work required for each protocol change.

This makes the project relevant not only as a research continuation of SpecTrum, but also as engineering infrastructure that can remain useful to Ethereum Protocol Security, consensus-spec contributors, client developers, and future researchers.

## 3.6. Enabling further research

The transpiler also opens a new research direction around maintaining mechanized specifications for large, evolving real-world protocols.

Depending on the technical results, the project may provide a basis for follow-up research on topics such as:

automated translation of executable specifications,
semantic preservation between specification languages,
incremental mechanization across protocol versions,
automatic derivation of specification-level test targets,
and combining mechanized specifications with fuzzing or constraint-based generation.

In this sense, the project aims to contribute both practical Ethereum security infrastructure and a broader research result on how mechanized specifications can be maintained as production protocols continuously evolve.
