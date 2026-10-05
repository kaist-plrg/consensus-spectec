"""
Line-based model of .spectec files: top-level blocks, declaration index, references.

Why not the real SpecTec parser:
- `plan` edits the previous fork's files and hands them to a human, so the output must
  keep every comment and the original layout. The only way the OCaml toolchain prints
  source back is `spectec-core unparse`, which drops comments and reformats everything.
  Here the blocks join back to the exact input, so only the touched blocks show in a diff.
- The parser is OCaml with no Python interface; using it would mean adding an AST dump
  command and an opam build to a tool that otherwise runs from `uv run` alone.
- `plan` only needs block boundaries, kinds, names and `$name` references, and the spec
  files keep every top-level declaration unindented.
"""

import re
from pathlib import Path
from typing import TypedDict

from .diff import FUNCS

TOP_KIND = re.compile(r"^(builtin|syntax|dec|def|relation|rule|var)\b")
NAME_RE = re.compile(
    r"^(?:builtin\s+dec|dec|def)\s+\$([A-Za-z_0-9]+)"
    r"|^(?:relation|rule|syntax|var)\s+([A-Za-z_0-9]+)"
)


class Block(TypedDict):
    """A top-level chunk of a .spectec file; joining every `text` restores the file."""

    kind: str  # builtin/syntax/dec/def/relation/rule/var, or comment/other
    name: str | None
    text: str


Ref = tuple[str, str, str | None]  # (file, kind, name) of a referencing block


def parse_blocks(text: str) -> list[Block]:
    """Top-level blocks. A block starts at a non-indented line; indented, blank and
    `)` lines continue it."""
    blocks: list[Block] = []
    for line in text.splitlines(keepends=True):
        starts = line.strip() and not line[0].isspace() and not line.startswith(")")
        if starts or not blocks:
            m = TOP_KIND.match(line)
            kind = "comment" if line.startswith(";;") else (m.group(1) if m else "other")
            n = NAME_RE.match(line)
            blocks.append(
                {"kind": kind, "name": (n.group(1) or n.group(2)) if n else None, "text": line}
            )
        else:
            blocks[-1]["text"] += line
    return blocks


def norm(s: str) -> str:
    return s.replace("_", "").lower()


def camel(snake: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in snake.split("_"))


def lower_camel(name: str) -> str:
    k = len(name) - len(name.lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    if k <= 1:
        return name[:1].lower() + name[1:]
    if k == len(name):
        return name.lower()
    return name[: k - 1].lower() + name[k - 1 :]  # KZGCommitment -> kzgCommitment


def strip_comments(text: str) -> str:
    return re.sub(r";;.*", "", text)


class Spec:
    DECLS = ("dec", "builtin", "relation", "syntax", "var")

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.files: dict[str, list[Block]] = {
            p.name: parse_blocks(p.read_text()) for p in sorted(self.root.glob("*.spectec"))
        }
        # name -> (kind, file); file is None for declarations plan generates
        self.decls: dict[str, tuple[str, str | None]] = {}
        for f, bs in self.files.items():
            for b in bs:
                if b["kind"] in self.DECLS and b["name"]:
                    self.decls.setdefault(b["name"], (b["kind"], f))

    def by_norm(self, key: str) -> list[str]:
        return [n for n in self.decls if norm(n) == norm(key)]

    def owners(self, cat: str, pyname: str) -> list[str]:
        """SpecTec declarations that translate this upstream symbol."""
        base = pyname.split(".")[-1]  # ExecutionEngine.notify_new_payload -> notify_new_payload
        found = self.by_norm(base)
        if cat in FUNCS:
            prefixes = (base.lower() + "_", camel(base).lower() + "_")  # ProcessSlots_loop, $f_loop
            found += [n for n in self.decls if n.lower().startswith(prefixes) and n not in found]
            if cat == "protocols":  # engine methods are $ee_* builtins
                found += [
                    n
                    for n in self.decls
                    if self.decls[n][0] == "builtin"
                    and re.fullmatch(r"[a-z]+_" + re.escape(base), n)
                    and n not in found
                ]
        return found

    def strip_bodies(self, decl: str) -> list[str]:
        body_kind = {"dec": "def", "relation": "rule"}.get(self.decls[decl][0])
        removed: list[Block] = []
        if body_kind:
            for f, bs in self.files.items():
                keep: list[Block] = []
                for b in bs:
                    (removed if b["kind"] == body_kind and b["name"] == decl else keep).append(b)
                self.files[f] = keep
        return [b["text"] for b in removed]

    def insert(self, decl: str, text: str, after: bool = True) -> None:
        kind, f = self.decls[decl]
        assert f is not None, f"{decl} is generated, not in a file"
        bs = self.files[f]
        i = next(i for i, b in enumerate(bs) if b["kind"] == kind and b["name"] == decl)
        bs.insert(i + 1 if after else i, {"kind": "comment", "name": None, "text": text})

    def replace_defs(self, decl: str, text: str) -> str | None:
        for f, bs in self.files.items():
            for b in bs:
                if b["kind"] == "def" and b["name"] == decl:
                    b["text"] = text
                    return f
        return None

    def references(self, name: str) -> list[Ref]:
        kind = self.decls[name][0]
        pat = (
            re.compile(r"\$" + re.escape(name) + r"\b")
            if kind in ("dec", "builtin")
            else re.compile(r"(?<![A-Za-z_0-9$])" + re.escape(name) + r"\b")
        )
        refs: set[Ref] = set()
        for f, bs in self.files.items():
            for b in bs:
                if b["kind"] in ("comment", "other") or b["name"] == name:
                    continue
                if pat.search(strip_comments(b["text"])):
                    refs.add((f, b["kind"], b["name"]))
        return sorted(refs)

    def write(self, dest: Path) -> None:
        dest.mkdir(parents=True, exist_ok=True)
        for f, bs in self.files.items():
            (dest / f).write_text("".join(b["text"] for b in bs))


def comment(lines: list[str]) -> str:
    return "".join((";; " + line).rstrip() + "\n" for line in lines)
