"""`plan`: copy the previous fork, stub changed definitions, write PLAN.md."""

import argparse
import difflib
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from .diff import VARS, Change, Diff, Source, load_diff
from .spectec import Spec, comment, lower_camel, parse_blocks, strip_comments


def render_src(src: Source | None) -> list[str]:
    if src is None:
        return []
    if isinstance(src, str):
        return src.splitlines()
    return [f"{src['type']} = {src['value']}"]


def todo(tag: str, ch: Change, note: str) -> str:
    head = [f"{tag}: {ch['category']} `{ch['name']}` {ch['kind']} upstream in {ch['doc']}", note]
    if ch["kind"] in ("changed", "doc_only"):
        body = list(
            difflib.unified_diff(
                render_src(ch["old"]), render_src(ch["new"]), "old", "new", n=2, lineterm=""
            )
        )
    else:
        body = render_src(ch["new"] if ch["new"] is not None else ch["old"])
    return comment(head + body) + "\n"


def as_int(value: object) -> int | None:
    """Python constant literal -> int, or None: 4096, 2**12, uint64(2**12), Bytes1('0x01')."""
    v = str(value).strip()
    m = re.fullmatch(r"(?:\w+\()?'?(0x[0-9a-fA-F]+)'?\)?", v)
    if m:
        return int(m.group(1), 16)
    v = re.sub(r"^\w+\((.*)\)$", r"\1", v)
    if re.fullmatch(r"[0-9_ *+\-()]+", v):
        try:
            return int(eval(v, {"__builtins__": {}}, {}))  # regex above limits this to arithmetic
        except Exception:
            return None
    return None


def spectec_type(spec: Spec, pytype: object) -> str | None:
    if not isinstance(pytype, str) or not pytype:
        return None
    m = re.fullmatch(r"Bytes(\d+)", pytype)
    if m:
        return f"bytes{m.group(1)}"
    if re.fullmatch(r"uint\d+|bool|boolean", pytype):
        return {"boolean": "bool"}.get(pytype, pytype)
    hits = [n for n in spec.by_norm(pytype) if spec.decls[n][0] == "syntax"]
    return hits[0] if len(hits) == 1 else None


def cmd_plan(a: argparse.Namespace) -> None:
    try:
        diff = load_diff(Path(a.diff))
    except (OSError, ValueError) as e:  # JSONDecodeError is a ValueError
        sys.exit(f"{a.diff}: not a `forkdiff diff` output: {e}")

    fork = a.tag or diff["to"]
    TODO, REVIEW = f"TODO({fork})", f"REVIEW({fork})"
    docs = None if a.docs == ["all"] else set(a.docs)
    dest = Path(a.to)
    if dest.exists() and any(dest.iterdir()) and not a.force:
        sys.exit(f"{dest} is not empty; pass --force to overwrite its .spectec files and PLAN.md")

    spec = Spec(a.from_dir)
    rep: defaultdict[str, list[Any]] = defaultdict(list)  # PLAN.md section -> rows
    stripped: set[str] = set()
    removed_texts: list[str] = []
    extra: list[str] = []

    def in_scope(ch: Change) -> bool:
        return docs is None or Path(ch["doc"]).name in docs

    for ch in diff["changes"]:
        if not in_scope(ch):
            rep["out_of_scope"].append(ch)
            continue
        cat, kind, name = ch["category"], ch["kind"], ch["name"]
        old, new = ch["old"], ch["new"]
        owners = spec.owners(cat, name)
        # Added upstream: no counterpart yet, so everything goes to the new 99-<fork>-todo file.
        if kind == "added":
            # Custom type with a known SpecTec type: generate `syntax x = T`.
            if cat == "custom_types" and (t := spectec_type(spec, new)):
                sname = lower_camel(name)
                extra.append(f";; [{fork}] {name} = {new}\nsyntax {sname} = {t}\n\n")
                spec.decls[sname] = ("syntax", None)  # later constants may use it
                rep["generated"].append((f"syntax {sname} = {t}", name))
            # Constant with a known type and an int value: generate `dec $X : T` + `def $X = N`.
            elif (
                cat in VARS
                and isinstance(new, dict)
                and (t := spectec_type(spec, new["type"]))
                and (v := as_int(new["value"])) is not None
            ):
                hexnote = f"  ;; {new['value']}" if "0x" in new["value"] else ""
                extra.append(
                    f";; [{fork}] {ch['doc']}\ndec ${name} : {t}\ndef ${name} = {v}{hexnote}\n\n"
                )
                rep["generated"].append((f"dec ${name} : {t} = {v}", name))
            # Anything else: a TODO comment holding the Python source.
            else:
                extra.append(
                    todo(TODO, ch, "new upstream definition: translate it (declaration + body)")
                )
                rep["todo_new"].append(ch)
            continue
        if not owners:
            rep["unmapped"].append(ch)
            continue

        # Existing symbol: patch every SpecTec declaration that translates it.
        for decl in owners:
            dkind, dfile = spec.decls[decl]
            # Docstring-only change: keep the body, add a REVIEW comment before it.
            if kind == "doc_only":
                spec.insert(
                    decl,
                    todo(
                        REVIEW,
                        ch,
                        "comment/docstring-only change upstream; body kept, review the contract",
                    ),
                    after=False,
                )
                rep["marked"].append((decl, dfile, name, kind))
            # Constant whose new value is an int: rewrite its `def` in place.
            elif (
                dkind == "dec"
                and cat in VARS
                and kind == "changed"
                and isinstance(old, dict)
                and isinstance(new, dict)
                and (v := as_int(new["value"])) is not None
            ):
                hexnote = f"  ;; {new['value']}" if "0x" in new["value"] else ""
                f = spec.replace_defs(
                    decl, f"def ${decl} = {v}{hexnote}  ;; [{fork}] was {old['value']}\n"
                )
                rep["generated"].append((f"def ${decl} = {v}", name)) if f else rep[
                    "marked"
                ].append((decl, dfile, name, kind))
            # Changed/removed dec or relation: strip the def/rule bodies, leave a TODO (a stub).
            elif dkind in ("dec", "relation") and kind in ("changed", "removed"):
                bodies = spec.strip_bodies(decl)
                removed_texts += bodies
                if kind == "changed":
                    # keep the old body as a comment: uncommenting it and applying the diff
                    # is usually a few-line edit, not a rewrite
                    note = "body commented out below: uncomment it and apply the diff above"
                    text = todo(TODO, ch, note) + comment("".join(bodies).rstrip().splitlines())
                    text += "\n"
                else:
                    note = "removed upstream: delete this declaration once nothing references it"
                    text = todo(TODO, ch, note)
                spec.insert(decl, text, after=True)
                stripped.add(decl)
                rep["stripped"].append((decl, dfile, name, kind))
            # syntax (types, containers), builtin, var: nothing to strip, add a TODO before it.
            else:
                note = {
                    "builtin": "OCaml builtin (spectec/targets/ethereum/builtins); check it",
                    "syntax": "edit the type/fields by hand; callers listed in PLAN.md",
                }.get(dkind, "review")
                spec.insert(decl, todo(TODO, ch, note), after=False)
                rep["marked"].append((decl, dfile, name, kind))

    if extra:
        head = (
            comment(
                [
                    f"[{fork}] additions with no counterpart in {a.from_dir}: "
                    "generated declarations and TODOs.",
                    "Move them into the topical files once translated.",
                ]
            )
            + "\n"
        )
        spec.files[f"99-{fork}-todo.spectec"] = parse_blocks(head + "".join(extra))

    # callers of every stripped/marked declaration
    touched = stripped | {d for d, _, _, kind in rep["marked"] if kind != "doc_only"}
    for decl in sorted(touched):
        for f, k, n in spec.references(decl):
            if n not in touched:
                rep["callers"].append((decl, f, k, n))
    # SpecTec-only helpers that only the stripped bodies used: they may need the same change,
    # or can go if the new body drops them
    used = set()
    for t in removed_texts:
        t = strip_comments(t)
        used |= set(re.findall(r"\$([a-z][A-Za-z_0-9]*)", t))
        used |= set(re.findall(r"--\s*([A-Z][A-Za-z_0-9]*)\s*:", t))
    for n in sorted(used):
        if (
            n in spec.decls
            and n not in stripped
            and spec.decls[n][0] in ("dec", "relation")
            and not spec.references(n)
        ):
            rep["orphans"].append((n, spec.decls[n][1]))

    spec.write(dest)
    (dest / "PLAN.md").write_text(render_plan(diff, a, fork, rep, docs))
    print(f"wrote {len(spec.files)} files + PLAN.md to {dest}")
    sections = (
        "stripped",
        "marked",
        "generated",
        "todo_new",
        "unmapped",
        "callers",
        "out_of_scope",
    )
    print(", ".join(f"{k.replace('_', '-')} {len(rep[k])}" for k in sections))
    print(
        f"next: ./spectec-core elab {dest}/*.spectec   "
        "(warnings Dec_missing_clauses / Relation_missing_rules are the TODOs)"
    )


def render_plan(
    diff: Diff,
    a: argparse.Namespace,
    fork: str,
    rep: defaultdict[str, list[Any]],
    docs: set[str] | None,
) -> str:
    L = [
        f"# Port plan: {diff['from']} -> {diff['to']}",
        "",
        f"- upstream: `{diff['specs']}` @ `{diff['rev']}` preset `{diff['preset']}`",
        f"- source: `{a.from_dir}` -> output: `{a.to}`",
        f"- docs in scope: {'all' if docs is None else ', '.join(sorted(docs))}",
        "",
    ]

    def table(title: str, header: tuple[str, ...], rows: list[Any], fmt) -> None:
        if not rows:
            return
        L.extend(
            [
                f"## {title} ({len(rows)})",
                "",
                "| " + " | ".join(header) + " |",
                "|" + "---|" * len(header),
            ]
        )
        L.extend("| " + " | ".join(fmt(r)) + " |" for r in rows)
        L.append("")

    table(
        "Stripped to a stub (fill these in)",
        ("SpecTec", "file", "upstream symbol", "kind"),
        rep["stripped"],
        lambda r: (f"`{r[0]}`", r[1], f"`{r[2]}`", r[3]),
    )
    table(
        "Marked with a TODO/REVIEW comment (edit by hand)",
        ("SpecTec", "file", "upstream symbol", "kind"),
        rep["marked"],
        lambda r: (f"`{r[0]}`", r[1], f"`{r[2]}`", r[3]),
    )
    table(
        "Generated deterministically",
        ("declaration", "upstream symbol"),
        rep["generated"],
        lambda r: (f"`{r[0]}`", f"`{r[1]}`"),
    )
    table(
        f"New upstream definitions left as TODO in 99-{fork}-todo.spectec",
        ("category", "upstream symbol", "doc"),
        rep["todo_new"],
        lambda c: (c["category"], f"`{c['name']}`", c["doc"]),
    )
    table(
        "Callers of touched declarations (re-check after rewriting)",
        ("touched", "file", "kind", "referencing"),
        rep["callers"],
        lambda r: (f"`{r[0]}`", r[1], r[2], f"`{r[3]}`"),
    )
    table(
        "SpecTec-only helpers used only by stubbed bodies (update with them, or delete if unused)",
        ("helper", "file"),
        rep["orphans"],
        lambda r: (f"`{r[0]}`", r[1]),
    )
    table(
        "In-scope upstream changes with no SpecTec counterpart "
        "(out of translation scope, or missing)",
        ("category", "upstream symbol", "kind", "doc"),
        rep["unmapped"],
        lambda c: (c["category"], f"`{c['name']}`", c["kind"], c["doc"]),
    )
    by_doc: defaultdict[str, list[str]] = defaultdict(list)
    for c in rep["out_of_scope"]:
        by_doc[c["doc"]].append(f"{c['name']} ({c['kind']})")
    if by_doc:
        L.extend([f"## Out-of-scope docs ({len(rep['out_of_scope'])} changes)", ""])
        for doc, names in sorted(by_doc.items()):
            L.append(f"- `{doc}`: " + ", ".join(sorted(names)))
        L.append("")
    L.extend(
        [
            "## Next",
            "",
            f"    ./spectec-core elab {a.to}/*.spectec",
            "",
            "Warnings `Dec_missing_clauses` / `Relation_missing_rules` are the open TODOs.",
            "",
        ]
    )
    return "\n".join(L)
