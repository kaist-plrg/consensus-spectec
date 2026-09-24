import argparse
import inspect
import itertools
import json
import subprocess
from pathlib import Path

from capella import dependency_slice, run, type_name


def wrappers(module, reference):
    text = []
    for name, mapping in reference.items():
        if "relation" in mapping:
            continue
        function = inspect.signature(getattr(module, name))
        parameters = list(function.parameters.values())
        types = " ".join(type_name(parameter.annotation) for parameter in parameters)
        values = list(mapping["arguments"].values())
        hints = " ".join(f"%{i}" for i in range(len(parameters)))
        text.append(
            f"relation Test_{name}: {types} |- {type_name(function.return_annotation)}\n  hint(input {hints})\nrule Test_{name}: {' '.join(values)} |- ${name}({', '.join(values)})\n"
        )
    return "\n".join(text)


def decode(kind, value):
    if hasattr(kind, "fields"):
        fields = kind.fields()
        return kind(
            **{
                name.lower(): decode(fields[name.lower()], item)
                for name, item in value.items()
            }
        )
    if hasattr(kind, "element_cls"):
        if isinstance(value, dict) and "repeat" in value:
            value = [value["value"]] * value["repeat"]
        return kind(*(decode(kind.element_cls(), item) for item in value))
    if isinstance(value, str) and value.startswith("0x"):
        return kind(bytes.fromhex(value[2:]))
    return kind(value)


def normalized(value):
    if isinstance(value, dict):
        return {key.lower(): normalized(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalized(item) for item in value]
    if isinstance(value, str) and value.lstrip("+-").isdigit():
        return int(value)
    if hasattr(value, "to_obj"):
        return normalized(value.to_obj())
    return value


def cases(module):
    maximum = 2**64 - 1
    tests = []
    for name in ["increase_balance", "decrease_balance"]:
        for balances, index, delta in [
            ([], 0, 0),
            ([0], 1, 1),
            ([0], 0, 0),
            ([0], 0, 1),
            ([1], 0, 0),
            ([1], 0, 1),
            ([1], 0, 2),
            ([maximum], 0, 0),
            ([maximum], 0, 1),
            ([maximum - 1, 9], 0, 1),
            ([maximum - 1], 0, 2),
            ([1, 2], 1, maximum),
        ]:
            tests.append(
                (
                    name,
                    [
                        {"BALANCES": balances, "GENESIS_TIME": 42, "SLOT": 96},
                        index,
                        delta,
                    ],
                )
            )
    for slot in [0, 1, 31, 32, 33, 63, 64, 8192, maximum]:
        tests.append(("get_previous_epoch", [{"SLOT": slot}]))
        for finalized in [0, 1, max(0, slot // 32 - 1), slot // 32, maximum]:
            tests.append(
                (
                    "get_finality_delay",
                    [{"SLOT": slot, "FINALIZED_CHECKPOINT": {"EPOCH": finalized}}],
                )
            )
    for activation, exit_epoch, epoch, slashed in itertools.product(
        [0, 10], [10, 20], [0, 9, 10, 19, 20], [False, True]
    ):
        validator = {
            "ACTIVATION_EPOCH": activation,
            "EXIT_EPOCH": exit_epoch,
            "WITHDRAWABLE_EPOCH": exit_epoch,
            "SLASHED": slashed,
        }
        for name in ["is_active_validator", "is_slashable_validator"]:
            tests.append((name, [validator, epoch]))
    for state_slot, slot in [
        (0, 0),
        (1, 0),
        (8192, 0),
        (8193, 0),
        (8193, 1),
        (8193, 8192),
        (8193, 8193),
        (maximum, maximum - 1),
        (maximum, maximum),
        (maximum, maximum - 8192),
    ]:
        tests.append(
            (
                "get_block_root_at_slot",
                [
                    {
                        "SLOT": state_slot,
                        "BLOCK_ROOTS": {"repeat": 8192, "value": "0x" + "12" * 32},
                    },
                    slot,
                ],
            )
        )
    for slot in [0, 31, 32, 2015, 2016, 2047, 2048, maximum]:
        tests.append(
            (
                "process_eth1_data_reset",
                [
                    {
                        "SLOT": slot,
                        "GENESIS_TIME": 42,
                        "ETH1_DATA_VOTES": [{"DEPOSIT_COUNT": 7}],
                    }
                ],
            )
        )
    return tests


def evaluate(runner, spec, requests):
    process = subprocess.run(
        check=False,
        args=[str(runner), str(spec)],
        input="".join(json.dumps(request) + "\n" for request in requests),
        capture_output=True,
        text=True,
        timeout=180,
    )
    if process.returncode:
        raise RuntimeError(process.stderr)
    values = [json.loads(line) for line in process.stdout.splitlines()]
    if len(values) != len(requests):
        raise RuntimeError("Missing runner responses")
    return values


def compare(module, reference, output, runner):
    generation = json.loads((output / "report.json").read_text())
    requests, direct_requests, expectations, identities = [], [], [], []
    for name, inputs in cases(module):
        function = getattr(module, name)
        kinds = [
            parameter.annotation
            for parameter in inspect.signature(function).parameters.values()
        ]
        arguments = [decode(kind, value) for kind, value in zip(kinds, inputs)]
        try:
            returned = function(*arguments)
            if "relation" in reference[name]:
                expected = {
                    key.lower(): normalized(getattr(arguments[0], key.lower()))
                    for key in inputs[0]
                }
            else:
                expected = normalized(returned)
            expectation = {"status": "ok", "value": expected}
        except (
            ValueError,
            IndexError,
            AssertionError,
            OverflowError,
            ZeroDivisionError,
        ) as error:
            expectation = {"status": "error", "exception": type(error).__name__}
        for mode in ["il", "sl"]:
            requests.append(
                {
                    "relation": reference[name].get("relation", "Test_" + name),
                    "typed_args": [
                        {"type": type_name(kind), "value": value}
                        for kind, value in zip(kinds, inputs)
                    ],
                    "mode": mode,
                }
            )
            direct_requests.append(
                {
                    **requests[-1],
                    "relation": generation["comparison_adapters"]
                    .get(name, {})
                    .get("generated_relation", requests[-1]["relation"]),
                }
            )
            expectations.append(expectation)
            identities.append({"function": name, "inputs": inputs, "mode": mode})
    adapter_indices = [
        index
        for index, identity in enumerate(identities)
        if identity["function"] in generation["comparison_adapters"]
    ]
    suffix = wrappers(module, reference)
    results = {}
    closures = {}
    for variant in ["manual", "replaced"]:
        path = output / f"{variant}_test.spectec"
        sliced, closures[variant] = dependency_slice(
            (output / f"{variant}.spectec").read_text(), reference
        )
        path.write_text(sliced + "\n" + suffix)
        results[variant] = evaluate(
            runner, path, requests if variant == "manual" else direct_requests
        )
        if variant == "replaced":
            results["adapted"] = dict(
                zip(
                    adapter_indices,
                    evaluate(
                        runner, path, [requests[index] for index in adapter_indices]
                    ),
                )
            )
    failures = []
    counts = {}
    adapter_failures = []
    for index, (identity, expected, manual, generated) in enumerate(
        zip(identities, expectations, results["manual"], results["replaced"])
    ):
        adapted = results["adapted"].get(index, generated)
        name = identity["function"]
        counts.setdefault(
            name, {"evaluations": 0, "successful_results": 0, "rejections": 0}
        )
        counts[name]["evaluations"] += 1
        counts[name][
            "successful_results" if expected["status"] == "ok" else "rejections"
        ] += 1
        equal = manual["status"] == generated["status"] == expected["status"]
        if equal and expected["status"] == "ok":
            left, right = (
                normalized(manual["json_values"]),
                normalized(generated["json_values"]),
            )
            equal = left == right and len(right) == 1
            value = right[0] if equal else None
            if equal and "relation" in reference[name]:
                equal = all(
                    value[key] == item for key, item in expected["value"].items()
                )
            elif equal:
                equal = value == expected["value"]
        adapter_equal = adapted["status"] == generated["status"]
        if adapter_equal and generated["status"] == "ok":
            adapter_equal = normalized(adapted["json_values"]) == normalized(
                generated["json_values"]
            )
        if not adapter_equal:
            adapter_failures.append(
                {"case": identity, "generated": generated, "adapted": adapted}
            )
        if not equal:
            failures.append(
                {
                    "case": identity,
                    "expected": expected,
                    "manual": manual,
                    "generated": generated,
                }
            )
    report = {
        "three_way_evaluations": len(requests),
        "passed": len(requests) - len(failures),
        "failed": len(failures),
        "adapter_evaluations": len(adapter_indices),
        "adapter_passed": len(adapter_indices) - len(adapter_failures),
        "adapter_failed": len(adapter_failures),
        "adapter_failures": adapter_failures,
        "entry_points": {
            "manual": "Handwritten interfaces",
            "generated": "Source-derived interfaces, with generated mutators namespaced in replaced.spectec",
            "adapted": "Handwritten caller interfaces forwarding to generated mutators",
        },
        "per_function": counts,
        "failures": failures,
        "dependency_closures": closures,
        "fixture_scope": "The Python oracle uses real SSZ objects. SpecTec uses its existing type declarations with defaults for untouched fields. Entire manual/generated SpecTec results are compared, with Python comparisons on supplied state fields. A dependency slice avoids an unrelated whole-corpus structuring failure. This is not a complete SSZ state-transition test.",
    }
    (output / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    for filename, entries in {
        "cases.jsonl": requests,
        "generated_cases.jsonl": direct_requests,
        "adapter_cases.jsonl": [requests[index] for index in adapter_indices],
    }.items():
        (output / filename).write_text(
            "".join(json.dumps(request) + "\n" for request in entries)
        )
    print(
        json.dumps(
            {
                key: value
                for key, value in report.items()
                if key
                not in {
                    "per_function",
                    "failures",
                    "adapter_failures",
                    "entry_points",
                    "fixture_scope",
                }
            }
        )
    )
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Compare generated Capella, handwritten Capella, and pinned Python"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--presentation-overrides", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    module, reference, _ = run(
        args.source.resolve(),
        args.reference.resolve(),
        output,
        args.presentation_overrides.resolve() if args.presentation_overrides else None,
    )
    report = compare(module, reference, output, args.runner.resolve())
    raise SystemExit(int(bool(report["failed"] or report["adapter_failed"])))
