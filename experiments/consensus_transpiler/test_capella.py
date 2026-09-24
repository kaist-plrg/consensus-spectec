import ast
import inspect
import json
import os
import tempfile
import unittest
from pathlib import Path
from textwrap import dedent
from unittest.mock import patch

from capella import (
    Lowerer,
    Unsupported,
    assemble,
    comparison_replacements,
    dependency_slice,
    replace_definitions,
)
from capella_interfaces import read_overrides
from verify_capella import decode, evaluate, normalized, wrappers


@unittest.skipUnless(
    os.environ.get("CAPELLA_SOURCE"), "Set CAPELLA_SOURCE to the pinned checkout"
)
class CapellaLoweringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]
        cls.module, _ = assemble(Path(os.environ["CAPELLA_SOURCE"]).resolve())
        cls.reference = json.loads(
            Path(__file__).with_name("capella_reference.json").read_text()
        )
        cls.manual = "\n".join(
            path.read_text()
            for path in sorted((cls.root / "spec/spec_capella").glob("*.spectec"))
        )
        cls.runner = (
            cls.root / "_build/default/experiments/consensus_transpiler/runner.exe"
        )

    def execute(self, name, source, inputs, overrides=None):
        mapping = {name: self.reference[name]}
        lowerer = Lowerer(self.module, self.manual, overrides)
        generated, paths = lowerer.lower(name, ast.parse(source).body[0])
        adapted, adapters = comparison_replacements(
            {name: generated}, lowerer.interfaces, mapping, self.manual
        )
        replaced = replace_definitions(self.manual, adapted, mapping)
        sliced, _ = dependency_slice(replaced, mapping)
        relation = mapping[name].get("relation", "Test_" + name)
        requests = [
            {"relation": relation, "typed_args": arguments, "mode": mode}
            for arguments in inputs
            for mode in ["il", "sl"]
        ]
        with tempfile.TemporaryDirectory() as directory:
            spec = Path(directory) / "fixture.spectec"
            spec.write_text(sliced + "\n" + wrappers(self.module, mapping))
            direct = (
                [
                    {**request, "relation": adapters[name]["generated_relation"]}
                    for request in requests
                ]
                if name in adapters
                else []
            )
            results = evaluate(self.runner, spec, requests + direct)
            for adapted, generated in zip(
                results[: len(requests)], results[len(requests) :]
            ):
                self.assertEqual(adapted["status"], generated["status"])
                if adapted["status"] == "ok":
                    self.assertEqual(adapted["json_values"], generated["json_values"])
            return paths, results[: len(requests)]

    def balance_input(self, balance, delta):
        return [
            {"type": "beaconState", "value": {"BALANCES": balance}},
            {"type": "validatorIndex", "value": 0},
            {"type": "gwei", "value": delta},
        ]

    def test_default_interfaces_do_not_read_manual_declarations_or_arguments(self):
        source = ast.parse(inspect.getsource(self.module.increase_balance)).body[0]
        with_manual, _ = Lowerer(self.module, self.manual).lower(
            "increase_balance", source
        )
        without_manual, _ = Lowerer(self.module, "").lower("increase_balance", source)
        self.assertEqual(with_manual, without_manual)
        self.assertTrue(
            with_manual.startswith(
                "relation IncreaseBalance: beaconState validatorIndex gwei ~> beaconState\n"
            )
        )
        self.assertIn(
            "beaconState_state validatorIndex_index gwei_delta ~>", with_manual
        )
        self.assertNotIn("'.' BALANCES", with_manual)
        interface = Lowerer(self.module, "").interfaces["is_active_validator"]
        self.assertEqual(
            interface.declaration(),
            "dec $is_active_validator(validator, epoch) : boolean",
        )
        self.assertEqual(
            interface.arguments,
            {"validator": "validator_validator", "epoch": "epoch_epoch"},
        )

    def test_custom_presentation_preserves_results_and_rejections_through_adapters(
        self,
    ):
        overrides = {
            "increase_balance": {
                "relation": "AddBalance",
                "arguments": {
                    "state": "state_input",
                    "index": "vid_position",
                    "delta": "delta_value",
                },
                "notation": "{state} '.' BALANCES `[ {index} `] '+' {delta} ~> {result}",
            }
        }
        lowerer = Lowerer(self.module, self.manual, overrides)
        source = inspect.getsource(self.module.increase_balance)
        generated, _ = lowerer.lower("increase_balance", ast.parse(source).body[0])
        self.assertIn(
            "relation AddBalance: beaconState '.' BALANCES `[ validatorIndex `] '+' gwei ~> beaconState",
            generated,
        )
        self.assertIn(
            "state_input '.' BALANCES `[ vid_position `] '+' delta_value", generated
        )
        _, results = self.execute(
            "increase_balance",
            source,
            [
                self.balance_input([5], 3),
                self.balance_input([], 1),
                self.balance_input([2**64 - 1], 1),
            ],
            overrides,
        )
        self.assertEqual(
            [item["status"] for item in results],
            ["ok", "ok", "error", "error", "error", "error"],
        )
        self.assertEqual(normalized(results[0]["json_values"])[0]["balances"], [8])

    def test_comparison_adapters_only_forward_and_reject_namespace_collisions(self):
        lowerer = Lowerer(self.module, self.manual)
        source = ast.parse(inspect.getsource(self.module.increase_balance)).body[0]
        generated, _ = lowerer.lower("increase_balance", source)
        mapping = {"increase_balance": self.reference["increase_balance"]}
        _, adapters = comparison_replacements(
            {"increase_balance": generated}, lowerer.interfaces, mapping, self.manual
        )
        forwarding = adapters["increase_balance"]["forwarding_rule"]
        self.assertEqual(forwarding.count("  -- "), 1)
        self.assertNotIn("-- if", forwarding)
        self.assertIn(
            "-- GeneratedIncreaseBalance: state vid delta ~> beaconState_comparisonResult",
            forwarding,
        )
        with self.assertRaisesRegex(Unsupported, "Comparison relation name collision"):
            comparison_replacements(
                {"increase_balance": generated},
                lowerer.interfaces,
                mapping,
                self.manual
                + "\nrelation GeneratedIncreaseBalance: beaconState ~> beaconState\n",
            )

    def test_override_arguments_cannot_collide_with_generated_locals(self):
        overrides = {
            "increase_balance": {
                "arguments": {
                    "state": "state",
                    "index": "vid",
                    "delta": "balance_transpiled0",
                }
            }
        }
        _, results = self.execute(
            "increase_balance",
            inspect.getsource(self.module.increase_balance),
            [self.balance_input([5], 3)],
            overrides,
        )
        self.assertEqual([item["status"] for item in results], ["ok", "ok"])
        self.assertEqual(normalized(results[0]["json_values"])[0]["balances"], [8])

    def test_invalid_presentation_overrides_are_rejected(self):
        for overrides in [
            [],
            {"unreviewed": {}},
            {"increase_balance": {"unknown": "value"}},
            {"increase_balance": {"arguments": {"state": "state"}}},
            {
                "increase_balance": {
                    "arguments": {
                        "state": "state",
                        "index": "state_bad",
                        "delta": "delta",
                    }
                }
            },
            {"increase_balance": {"relation": "InitiateValidatorExit"}},
            {"increase_balance": {"relation": "DecreaseBalance"}},
            {"increase_balance": {"relation": "Bad name"}},
            {"increase_balance": {"notation": "{state} {delta} {index} ~> {result}"}},
            {
                "increase_balance": {
                    "notation": "{state} {index} {delta} ~> {result} {result}"
                }
            },
            {
                "increase_balance": {
                    "notation": "{state} {index} {delta} ~> {result}\n-- if true"
                }
            },
            {"increase_balance": {"notation": "{state} {index} {delta} ~> {unknown}"}},
            {"increase_balance": {"notation": "{state!r} {index} {delta} ~> {result}"}},
            {"is_active_validator": {"relation": "Predicate"}},
        ]:
            with self.subTest(overrides=overrides), self.assertRaises(Unsupported):
                Lowerer(self.module, self.manual, overrides)

    def test_override_json_rejects_duplicates_and_nonobjects(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "overrides.json"
            for text in [
                "null",
                "[]",
                "{",
                '{"increase_balance": {}, "increase_balance": {}}',
            ]:
                with self.subTest(text=text), self.assertRaises(Unsupported):
                    path.write_text(text)
                    read_overrides(path)
            path.write_text(
                '{"is_active_validator": {"arguments": {"validator": "validator_input", "epoch": "epoch_input"}}}'
            )
            _, overrides = read_overrides(path)
            interface = Lowerer(self.module, self.manual, overrides).interfaces[
                "is_active_validator"
            ]
            self.assertEqual(
                interface.arguments,
                {"validator": "validator_input", "epoch": "epoch_input"},
            )

    def test_unsupported_source_signatures_are_rejected(self):
        lowerer = Lowerer(self.module, self.manual)
        for parameters in [
            "state, index, delta=0",
            "state, index, *, delta",
            "state, index, *delta",
            "state, delta, index",
        ]:
            with self.subTest(parameters=parameters), self.assertRaises(Unsupported):
                lowerer.lower(
                    "increase_balance",
                    ast.parse(
                        f"def increase_balance({parameters}):\n    return\n"
                    ).body[0],
                )
        with self.assertRaisesRegex(Unsupported, "Unreviewed"):
            lowerer.lower("other", ast.parse("def other(state):\n    return\n").body[0])

        def invalid_mutator(state: int) -> None:
            pass

        with (
            patch.object(self.module, "increase_balance", invalid_mutator),
            self.assertRaisesRegex(Unsupported, "state-mutator signature"),
        ):
            Lowerer(self.module, self.manual)

    def test_early_return_does_not_evaluate_later_exception_sites(self):
        source = """def increase_balance(state, index, delta):
    if delta == 0:
        return
    state.balances[index] += delta
"""
        paths, results = self.execute(
            "increase_balance",
            source,
            [
                self.balance_input([], 0),
                self.balance_input([], 1),
                self.balance_input([2**64 - 1], 1),
            ],
        )
        self.assertEqual(
            [item["status"] for item in results],
            ["ok", "ok", "error", "error", "error", "error"],
        )
        self.assertEqual(
            {item["reason"] for item in paths[0]["premises"]}, {"path_condition"}
        )

    def test_continuation_runs_after_either_branch(self):
        source = """def increase_balance(state, index, delta):
    if delta > state.balances[index]:
        state.balances[index] = 0
    state.balances[index] += 1
"""
        _, results = self.execute(
            "increase_balance",
            source,
            [
                self.balance_input([5], 6),
                self.balance_input([5], 3),
                self.balance_input([2**64 - 1], 0),
            ],
        )
        for result, expected in zip(results[:4], [1, 1, 6, 6]):
            self.assertEqual(
                normalized(result["json_values"])[0]["balances"], [expected]
            )
        self.assertEqual([item["status"] for item in results[4:]], ["error", "error"])

    def test_rejection_does_not_expose_python_partial_state(self):
        def increase_balance(state, index, delta):
            state.balances[index] += delta
            state.balances[index] += delta

        source = dedent(inspect.getsource(increase_balance))
        maximum = 2**64 - 1
        index, delta = self.module.ValidatorIndex(0), self.module.Gwei(1)
        success_state = decode(self.module.BeaconState, {"BALANCES": [maximum - 2]})
        self.assertIsNone(increase_balance(success_state, index, delta))
        self.assertEqual(normalized(success_state.balances), [maximum])
        rejected_state = decode(self.module.BeaconState, {"BALANCES": [maximum - 1]})
        with self.assertRaises(ValueError):
            increase_balance(rejected_state, index, delta)
        self.assertEqual(normalized(rejected_state.balances), [maximum])

        _, results = self.execute(
            "increase_balance",
            source,
            [
                self.balance_input([maximum - 2], 1),
                self.balance_input([maximum - 1], 1),
            ],
        )
        self.assertEqual(
            [item["status"] for item in results], ["ok", "ok", "error", "error"]
        )
        for result in results[:2]:
            self.assertEqual(
                normalized(result["json_values"])[0]["balances"],
                normalized(success_state.balances),
            )
        for result in results[2:]:
            self.assertNotIn("json_values", result)

    def test_saved_checkpoint_survives_state_field_replacement(self):
        def process_eth1_data_reset(state):
            checkpoint = state.current_justified_checkpoint
            state.current_justified_checkpoint = state.previous_justified_checkpoint
            state.finalized_checkpoint = checkpoint

        inputs = {
            "CURRENT_JUSTIFIED_CHECKPOINT": {"EPOCH": 11, "ROOT": "0x" + "11" * 32},
            "PREVIOUS_JUSTIFIED_CHECKPOINT": {"EPOCH": 7, "ROOT": "0x" + "07" * 32},
        }
        state = decode(self.module.BeaconState, inputs)
        self.assertIsNone(process_eth1_data_reset(state))
        self.assertEqual(
            normalized(state.current_justified_checkpoint),
            normalized(inputs["PREVIOUS_JUSTIFIED_CHECKPOINT"]),
        )
        self.assertEqual(
            normalized(state.finalized_checkpoint),
            normalized(inputs["CURRENT_JUSTIFIED_CHECKPOINT"]),
        )
        _, results = self.execute(
            "process_eth1_data_reset",
            dedent(inspect.getsource(process_eth1_data_reset)),
            [[{"type": "beaconState", "value": inputs}]],
        )
        self.assertEqual([item["status"] for item in results], ["ok", "ok"])
        for result in results:
            actual = normalized(result["json_values"])[0]
            for field in ["current_justified_checkpoint", "finalized_checkpoint"]:
                self.assertEqual(actual[field], normalized(getattr(state, field)))

    def test_saved_checkpoint_passes_through_either_branch(self):
        def process_eth1_data_reset(state):
            checkpoint = state.current_justified_checkpoint
            if state.slot > 0:
                state.current_justified_checkpoint = state.previous_justified_checkpoint
            forwarded = checkpoint
            state.finalized_checkpoint = forwarded

        inputs = [
            {
                "SLOT": slot,
                "CURRENT_JUSTIFIED_CHECKPOINT": {"EPOCH": 11},
                "PREVIOUS_JUSTIFIED_CHECKPOINT": {"EPOCH": 7},
            }
            for slot in [0, 1]
        ]
        expected = []
        for item in inputs:
            state = decode(self.module.BeaconState, item)
            self.assertIsNone(process_eth1_data_reset(state))
            self.assertEqual(int(state.finalized_checkpoint.epoch), 11)
            self.assertEqual(
                int(state.current_justified_checkpoint.epoch), 7 if item["SLOT"] else 11
            )
            expected.extend([state, state])
        _, results = self.execute(
            "process_eth1_data_reset",
            dedent(inspect.getsource(process_eth1_data_reset)),
            [[{"type": "beaconState", "value": item}] for item in inputs],
        )
        self.assertEqual([item["status"] for item in results], ["ok"] * 4)
        for result, state in zip(results, expected):
            actual = normalized(result["json_values"])[0]
            for field in ["current_justified_checkpoint", "finalized_checkpoint"]:
                self.assertEqual(actual[field], normalized(getattr(state, field)))

    def test_saved_sequence_keeps_values_before_direct_element_update(self):
        def increase_balance(state, index, delta):
            balances = state.balances
            state.balances[index] += delta
            state.balances[index] += balances[index]

        state = decode(self.module.BeaconState, {"BALANCES": [5, 9]})
        self.assertIsNone(
            increase_balance(state, self.module.ValidatorIndex(0), self.module.Gwei(3))
        )
        self.assertEqual(normalized(state.balances), [13, 9])
        for overrides in [
            None,
            {
                "increase_balance": {
                    "arguments": {
                        "state": "state",
                        "index": "vid",
                        "delta": "gwei_transpiled0",
                    }
                }
            },
        ]:
            with self.subTest(overrides=overrides):
                _, results = self.execute(
                    "increase_balance",
                    dedent(inspect.getsource(increase_balance)),
                    [self.balance_input([5, 9], 3)],
                    overrides,
                )
                self.assertEqual([item["status"] for item in results], ["ok", "ok"])
                for result in results:
                    self.assertEqual(
                        normalized(result["json_values"])[0]["balances"],
                        normalized(state.balances),
                    )

    def test_saved_indexed_record_survives_element_replacement(self):
        def increase_balance(state, index, delta):
            validator = state.validators[index]
            state.validators[index] = state.validators[index + 1]
            state.balances[index] = validator.effective_balance

        inputs = {
            "VALIDATORS": [{"EFFECTIVE_BALANCE": 5}, {"EFFECTIVE_BALANCE": 11}],
            "BALANCES": [0, 0],
        }
        state = decode(self.module.BeaconState, inputs)
        self.assertIsNone(
            increase_balance(state, self.module.ValidatorIndex(0), self.module.Gwei(0))
        )
        self.assertEqual(normalized(state.balances), [5, 0])
        self.assertEqual(int(state.validators[0].effective_balance), 11)
        _, results = self.execute(
            "increase_balance",
            dedent(inspect.getsource(increase_balance)),
            [
                [
                    {"type": "beaconState", "value": inputs},
                    {"type": "validatorIndex", "value": 0},
                    {"type": "gwei", "value": 0},
                ]
            ],
        )
        self.assertEqual([item["status"] for item in results], ["ok", "ok"])
        for result in results:
            actual = normalized(result["json_values"])[0]
            self.assertEqual(actual["balances"], normalized(state.balances))
            self.assertEqual(actual["validators"], normalized(state.validators))

    def test_saved_record_can_be_passed_to_reviewed_pure_helper(self):
        is_active_validator = self.module.is_active_validator

        def is_slashable_validator(validator, epoch):
            saved = validator
            return is_active_validator(saved, epoch)

        validator_input = {"ACTIVATION_EPOCH": 10, "EXIT_EPOCH": 20}
        expected = []
        for epoch in [9, 10, 20]:
            validator = decode(self.module.Validator, validator_input)
            expected.append(
                normalized(is_slashable_validator(validator, self.module.Epoch(epoch)))
            )
        self.assertEqual(expected, [False, True, False])
        _, results = self.execute(
            "is_slashable_validator",
            dedent(inspect.getsource(is_slashable_validator)),
            [
                [
                    {"type": "validator", "value": validator_input},
                    {"type": "epoch", "value": epoch},
                ]
                for epoch in [9, 10, 20]
            ],
        )
        self.assertEqual([item["status"] for item in results], ["ok"] * 6)
        self.assertEqual(
            [normalized(item["json_values"])[0] for item in results],
            [value for value in expected for _ in ["il", "sl"]],
        )

    def test_saved_record_cannot_be_passed_to_unknown_effect_helper(self):
        def unreviewed(validator: self.module.Validator) -> self.module.boolean:
            validator.slashed = True
            return self.module.boolean(True)

        source = """def is_slashable_validator(validator, epoch):
    saved = validator
    return unreviewed(saved)
"""
        with patch.object(self.module, "unreviewed", unreviewed, create=True):
            lowerer = Lowerer(
                self.module,
                self.manual + "\ndec $unreviewed(validator) : boolean\n",
            )
            with self.assertRaises(Unsupported):
                lowerer.lower("is_slashable_validator", ast.parse(source).body[0])

    def test_locally_shadowed_helpers_and_casts_are_rejected(self):
        for body in [
            "    get_current_epoch = state.current_justified_checkpoint\n    epoch = get_current_epoch(state)\n",
            "    epoch = get_current_epoch(state)\n    get_current_epoch = state.current_justified_checkpoint\n",
            "    if False:\n        get_current_epoch = state.current_justified_checkpoint\n    epoch = get_current_epoch(state)\n",
            "    Epoch = state.current_justified_checkpoint\n    epoch = Epoch(state.slot)\n",
        ]:
            with (
                self.subTest(body=body),
                self.assertRaisesRegex(
                    Unsupported, "Calls through locally bound names"
                ),
            ):
                Lowerer(self.module, self.manual).lower(
                    "process_eth1_data_reset",
                    ast.parse("def process_eth1_data_reset(state):\n" + body).body[0],
                )

    def test_local_constant_read_before_assignment_is_rejected(self):
        source = """def process_eth1_data_reset(state):
    epoch = GENESIS_EPOCH
    GENESIS_EPOCH = state.slot
"""
        with self.assertRaisesRegex(Unsupported, "Read before local assignment"):
            Lowerer(self.module, self.manual).lower(
                "process_eth1_data_reset", ast.parse(source).body[0]
            )

    def test_short_circuit_failure_cannot_fall_into_false_case(self):
        source = """def is_slashable_validator(validator, epoch):
    return validator.slashed or validator.withdrawable_epoch + 1 > epoch
"""
        inputs = [
            [
                {
                    "type": "validator",
                    "value": {"SLASHED": slashed, "WITHDRAWABLE_EPOCH": 2**64 - 1},
                },
                {"type": "epoch", "value": 0},
            ]
            for slashed in [True, False]
        ]
        _, results = self.execute("is_slashable_validator", source, inputs)
        self.assertEqual(results[0]["json_values"], [True])
        self.assertEqual(results[1]["json_values"], [True])
        self.assertEqual([item["status"] for item in results[2:]], ["error", "error"])

    def test_loops_and_writes_through_saved_values_are_unsupported(self):
        lowerer = Lowerer(self.module, self.manual)
        for body in [
            "    for item in state.balances:\n        pass\n",
            "    saved = state\n",
            "    balances = state.balances\n    balances[index] += delta\n",
            "    validator = state.validators[index]\n    validator.effective_balance = delta\n",
            "    balances = state.balances\n    forwarded = balances\n    forwarded[index] = delta\n",
            "    checkpoint = state.current_justified_checkpoint\n    forwarded = checkpoint\n    forwarded.epoch = delta\n",
        ]:
            with self.subTest(body=body), self.assertRaises(Unsupported):
                lowerer.lower(
                    "increase_balance",
                    ast.parse(
                        "def increase_balance(state, index, delta):\n" + body
                    ).body[0],
                )


if __name__ == "__main__":
    unittest.main()
