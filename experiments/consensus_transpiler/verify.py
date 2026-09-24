import argparse
import itertools
import json
import random
import subprocess
import time
from pathlib import Path

from scalar import run


def samples(function, globals_used, seed=0):
    randomizer = random.Random(seed)
    domains = []
    for _, kind in function.parameters:
        if kind is bool:
            domains.append([False, True])
            continue
        if kind is int:
            values = {-129, -65, -2, -1, 0, 1, 2, 63, 64, 65, 127, 2**64 - 1}
        else:
            maximum = kind.MAX_VALUE
            values = {-1, 0, 1, 2, maximum // 2, maximum - 1, maximum, maximum + 1}
            for constant in globals_used.values():
                if constant["type"] != "bool":
                    number = int(constant["value"])
                    values.update(
                        value
                        for value in (number - 1, number, number + 1)
                        if 0 <= value <= maximum
                    )
        domains.append(sorted(values))
    if len(domains) <= 1:
        cases = list(itertools.product(*domains))
    else:
        cases = [tuple([0] * len(domains))]
        for index, domain in enumerate(domains):
            for value in domain:
                case = [0] * len(domains)
                case[index] = value
                cases.append(tuple(case))
        if len(domains) == 2:
            cases.extend((value, value) for value in set(domains[0]) & set(domains[1]))
    for _ in range(32):
        case = []
        for index, (_, kind) in enumerate(function.parameters):
            if kind is bool:
                case.append(randomizer.choice([False, True]))
            elif kind is int:
                case.append(randomizer.randint(-128, 128))
            elif randomizer.choice([True, False]):
                case.append(randomizer.randrange(kind.MAX_VALUE + 1))
            else:
                case.append(randomizer.choice(domains[index]))
        cases.append(tuple(case))
    return list(dict.fromkeys(cases))


def compare(compiler, spec_file, runner, cases_by_function, extra_cases=()):
    requests = []
    expected = []
    identities = []
    counts = {}
    for name, cases in cases_by_function.items():
        function = compiler.functions[name]
        counts[name] = {
            "inputs": len(cases),
            "returns": 0,
            "input_rejections": 0,
            "function_rejections": 0,
        }
        for case in cases:
            try:
                converted = [
                    kind(value) for value, (_, kind) in zip(case, function.parameters)
                ]
            except (ValueError, TypeError, OverflowError) as error:
                expectation = {
                    "status": "error",
                    "category": "input",
                    "exception": type(error).__name__,
                }
                counts[name]["input_rejections"] += 1
            else:
                try:
                    value = getattr(compiler.module, name)(*converted)
                    expectation = {
                        "status": "ok",
                        "value": bool(value) if type(value) is bool else int(value),
                    }
                    counts[name]["returns"] += 1
                except (
                    ValueError,
                    TypeError,
                    OverflowError,
                    AssertionError,
                    ZeroDivisionError,
                ) as error:
                    expectation = {
                        "status": "error",
                        "category": "function",
                        "exception": type(error).__name__,
                    }
                    counts[name]["function_rejections"] += 1
            for mode in ["il", "sl"]:
                requests.append(
                    {
                        "relation": f"Py_{name}",
                        "args": [
                            value if type(value) is bool else str(value)
                            for value in case
                        ],
                        "mode": mode,
                    }
                )
                expected.append(expectation)
                identities.append({"function": name, "args": list(case), "mode": mode})
    for request, expectation in extra_cases:
        requests.append(request)
        expected.append(expectation)
        identities.append(request)
    started = time.monotonic()
    process = subprocess.run(
        check=False,
        args=[str(runner), str(spec_file)],
        input="".join(json.dumps(request) + "\n" for request in requests),
        text=True,
        capture_output=True,
        timeout=180,
    )
    if process.returncode != 0:
        raise RuntimeError(
            f"SpecTec runner failed ({process.returncode}):\n{process.stderr}"
        )
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    if len(responses) != len(requests):
        raise RuntimeError(
            f"Expected {len(requests)} responses, received {len(responses)}"
        )
    failures = []
    for identity, want, actual in zip(identities, expected, responses):
        matches = want["status"] == actual["status"]
        if matches and want["status"] == "ok":
            values = actual["values"]
            if len(values) != 1:
                matches = False
            else:
                parsed = {"true": True, "false": False}.get(values[0])
                if parsed is None:
                    parsed = int(values[0])
                matches = (
                    type(parsed) is type(want["value"]) and parsed == want["value"]
                )
        if not matches:
            failures.append({"case": identity, "expected": want, "actual": actual})
    result = {
        "evaluations": len(requests),
        "passed": len(requests) - len(failures),
        "failed": len(failures),
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "per_function": counts,
        "failures": failures,
    }
    return result, requests


def main():
    parser = argparse.ArgumentParser(
        description="Compare generated scalar SpecTec against the pinned Python reference"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--preset", required=True, choices=["minimal", "mainnet"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runner", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    compiler, report = run(args.source.resolve(), args.preset, output)
    cases = {
        name: samples(function, compiler.global_values)
        for name, function in compiler.functions.items()
    }
    result, requests = compare(
        compiler, output / "scalar.spectec", args.runner.resolve(), cases
    )
    result["preset"] = args.preset
    result["seed"] = 0
    result["source_revision"] = report["manifest"]["revision"]
    (output / "validation.json").write_text(json.dumps(result, indent=2) + "\n")
    (output / "cases.jsonl").write_text(
        "".join(json.dumps(request) + "\n" for request in requests)
    )
    print(
        json.dumps(
            {
                key: value
                for key, value in result.items()
                if key not in {"per_function", "failures"}
            }
        )
    )
    return int(bool(result["failed"]))


if __name__ == "__main__":
    raise SystemExit(main())
