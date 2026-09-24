import tempfile
import unittest
from pathlib import Path

from inventory import inspect_files, python_blocks


class InventoryTests(unittest.TestCase):
    def inspect(self, contents):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "beacon-chain.md"
            path.write_text(contents)
            return inspect_files(root, [path])

    def test_line_provenance_and_mutation(self):
        report = self.inspect(
            "# Header\n\n```python\ndef process(state: State) -> None:\n    assert state.balance > 0\n    state.balance -= 1\n```\n"
        )
        definition = report["definitions"][0]
        self.assertEqual((definition["line"], definition["end_line"]), (4, 6))
        self.assertEqual(definition["evidence_lines"]["mutation"], 6)
        self.assertEqual(definition["evidence_lines"]["failure"], 5)
        self.assertEqual(report["summary"]["translated"], 0)

    def test_duplicate_definitions_are_preserved(self):
        report = self.inspect(
            "```python\ndef f():\n    return 1\n```\n```python\ndef f():\n    return 2\n```\n"
        )
        self.assertEqual(report["duplicate_names"], ["f"])
        self.assertEqual(report["summary"]["functions"], 2)

    def test_parse_errors_and_other_statements_are_reported(self):
        report = self.inspect("```python\ndef f(:\n```\n```python\nVALUE = 1\n```\n")
        self.assertEqual(report["errors"][0]["line"], 2)
        self.assertEqual(report["other_top_level_statements"][0]["kind"], "Assign")

    def test_nested_fence_is_not_treated_as_source(self):
        text = "````text\n```python\ndef fake(): pass\n```\n````\n~~~python\ndef real(): pass\n~~~\n"
        self.assertEqual(list(python_blocks(text)), [(7, "def real(): pass\n")])

    def test_unclosed_python_fence_fails(self):
        report = self.inspect("```python\ndef incomplete(): pass\n")
        self.assertEqual(len(report["errors"]), 1)

    def test_nested_methods_are_counted_inside_class(self):
        report = self.inspect(
            "```python\nclass Engine:\n    def call(self):\n        return external()\n```\n"
        )
        self.assertEqual(report["summary"]["classes"], 1)
        self.assertEqual(report["summary"]["functions"], 0)
        self.assertEqual(report["definitions"][0]["calls"], ["external"])


if __name__ == "__main__":
    unittest.main()
