import importlib.util
import itertools
import tempfile
import unittest
from pathlib import Path

from scalar import Compiler, Unsupported
from verify import compare

FIXTURE = """from ssz.uint import Uint8, Uint64

def add(a: Uint8, b: Uint8) -> Uint8:
    return a + b

def intermediate_overflow(a: Uint8) -> Uint8:
    return (a + 1) - 1

def discarded_overflow(a: Uint8) -> Uint8:
    unused = a + 1
    return a

def lazy_and(a: Uint8) -> bool:
    return a < 255 and a + 1 > a

def lazy_or(a: Uint8) -> bool:
    return a == 255 or a + 1 > a

def early_return(a: Uint8) -> Uint8:
    if a == 255:
        return a
    return a + 1

def select(a: Uint8) -> Uint8:
    return a if a == 255 else a + 1

def guarded(a: Uint8) -> Uint8:
    assert a > 0
    return a - 1

def reassign(a: Uint8) -> Uint8:
    b = a
    a = a + 1
    return b

def inverted(a: Uint8) -> int:
    return ~a

def mask(a: Uint8) -> Uint8:
    return a & ~8

def floor(a: int, b: int) -> int:
    return a // b

def remainder(a: int, b: int) -> int:
    return a % b

def bitand(a: int, b: int) -> int:
    return a & b

def bitor(a: int, b: int) -> int:
    return a | b

def bitxor(a: int, b: int) -> int:
    return a ^ b

def bad_loop(a: Uint8) -> Uint8:
    while a > 0:
        a = a - 1
    return a

def bad_call(a: Uint8) -> Uint8:
    return unknown(a)

def bad_types(a: Uint8, b: Uint64) -> Uint8:
    return a + b

def mutate(a: Uint8) -> Uint8:
    a.field = 0
    return a

def missing_return(a: Uint8) -> Uint8:
    if a > 0:
        return a
"""


class ScalarTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        source = self.root / "fixture.py"
        source.write_text(FIXTURE)
        spec = importlib.util.spec_from_file_location("scalar_fixture", source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.compiler = Compiler(self.module)

    def test_runtime_matches_python_on_semantic_boundaries(self):
        unary = [(value,) for value in [-1, 0, 1, 7, 8, 9, 254, 255, 256]]
        signed = list(
            itertools.product([-129, -65, -3, -1, 0, 1, 2, 3, 64, 128], repeat=2)
        )
        cases = {
            name: unary
            for name in [
                "intermediate_overflow",
                "discarded_overflow",
                "lazy_and",
                "lazy_or",
                "early_return",
                "select",
                "guarded",
                "reassign",
                "inverted",
                "mask",
            ]
        }
        cases["add"] = list(itertools.product([0, 1, 127, 128, 254, 255], repeat=2))
        cases.update(
            {
                name: signed
                for name in ["floor", "remainder", "bitand", "bitor", "bitxor"]
            }
        )
        for name in cases:
            self.compiler.function(name)
        spec_file = self.root / "fixture.spectec"
        spec_file.write_text(self.compiler.render())
        runner = (
            Path(__file__).resolve().parents[2]
            / "_build/default/experiments/consensus_transpiler/runner.exe"
        )
        result, _ = compare(self.compiler, spec_file, runner, cases)
        self.assertEqual(result["failures"], [])

    def test_unsupported_constructs_fail_closed(self):
        for name in ["bad_loop", "bad_call", "bad_types", "mutate", "missing_return"]:
            with self.subTest(name=name):
                with self.assertRaises(Unsupported):
                    self.compiler.function(name)
                self.assertNotIn(name, self.compiler.functions)

    def test_builder_only_functions_require_review(self):
        self.compiler.source_functions = set()
        with self.assertRaisesRegex(
            Unsupported, "Upstream builder code requires review"
        ):
            self.compiler.function("add")

    def test_rebound_function_requires_review(self):
        self.module.add = lambda a, b: a
        with self.assertRaisesRegex(Unsupported, "rebound"):
            self.compiler.function("add")


if __name__ == "__main__":
    unittest.main()
