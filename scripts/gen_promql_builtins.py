#!/usr/bin/env python3
"""Generate lua/grannos/builtins/promql.lua from the Prometheus repository.

Every name, signature and description comes from Prometheus itself, nothing is
written here by hand:

  promql/parser/functions.go   the authoritative function list, with argument
                               types (used to build a signature when the docs
                               give none) and the experimental flag
  docs/querying/functions.md   each function's documented signature and the
                               paragraph (or bullet) describing it
  docs/querying/operators.md   the aggregation operators, their signatures and
                               one-line descriptions

Usage:  scripts/gen_promql_builtins.py [git-ref]      (default: REF below)

Prints the functions the docs say nothing about, if any; those are emitted with
a signature built from their argument types and no description.
"""

from __future__ import annotations

import re
import sys
import urllib.request
from pathlib import Path

REF = "v3.14.0"
RAW = "https://raw.githubusercontent.com/prometheus/prometheus/{ref}/{path}"
OUT = Path(__file__).resolve().parent.parent / "lua" / "grannos" / "builtins" / "promql.lua"

# Go value types → the vocabulary the documentation uses in signatures.
ARG_TYPES = {
    "ValueTypeVector": "instant-vector",
    "ValueTypeMatrix": "range-vector",
    "ValueTypeScalar": "scalar",
    "ValueTypeString": "string",
}


def fetch(ref: str, path: str) -> str:
    with urllib.request.urlopen(RAW.format(ref=ref, path=path)) as resp:
        return resp.read().decode()


def strip_markdown(text: str) -> str:
    """Flatten a doc paragraph to plain prose: links to their text, code spans
    to their contents, whitespace collapsed."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = text.replace("`", "")
    return re.sub(r"\s+", " ", text).strip()


def describe(name: str, signature: str, text: str) -> str:
    """Turn the doc's sentence — which names the signature it is about
    ("`rate(v range-vector)` calculates …", "Similarly, `histogram_sum(v
    instant-vector)` returns …") or is a bullet's tail ("the average value …")
    — into a description that stands on its own."""
    text = strip_markdown(text)
    lead = strip_markdown(signature)
    at = text.find(lead)
    if at >= 0:
        text = text[at + len(lead):]
    text = text.lstrip(": ").strip()
    # A cross-reference into the rest of the page, which the hover lacks.
    text = re.sub(r"\s*\(see (?:details |the section )?below\)", "", text)
    return text[:1].upper() + text[1:]


def parse_functions_go(src: str) -> dict[str, dict]:
    """name → { args: [type…], variadic: int, experimental: bool }"""
    out = {}
    for m in re.finditer(r'\t"(\w+)": \{\n(.*?)\n\t\},', src, re.S):
        name, body = m.group(1), m.group(2)
        types = re.search(r"ArgTypes:\s*\[\]ValueType\{([^}]*)\}", body)
        args = [ARG_TYPES[t.strip()] for t in types.group(1).split(",") if t.strip()] if types else []
        variadic = re.search(r"Variadic:\s*(-?\d+)", body)
        out[name] = {
            "args": args,
            "variadic": int(variadic.group(1)) if variadic else 0,
            "experimental": "Experimental: true" in body,
        }
    return out


def built_signature(name: str, spec: dict) -> str:
    """A signature from argument types alone, for a function the docs skip."""
    args = list(spec["args"])
    if spec["variadic"] and args:
        args[-1] = args[-1] + "…"
    return f"{name}({', '.join(args)})"


def sections(md: str) -> list[tuple[str, str]]:
    """(header, body) per `## ` section."""
    parts = re.split(r"^## ", md, flags=re.M)[1:]
    return [(p.split("\n", 1)[0].strip(), p.split("\n", 1)[1] if "\n" in p else "") for p in parts]


def paragraphs(body: str) -> list[str]:
    return [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]


def bullets(body: str) -> list[tuple[str, str, str]]:
    """(name, signature, description) for every `* \\`name(args)\\`: text` bullet
    (or `* \\`name(args)\\` (text)` as operators.md writes them), continuation
    lines included."""
    out = []
    joined = re.sub(r"\n[ \t]+(?=\S)", " ", body)
    for line in joined.split("\n"):
        m = re.match(r"^\* `(\w+)(\([^)]*\))`\s*(?::\s*(.*)|\((.*)\))\s*$", line)
        if m:
            out.append((m.group(1), m.group(1) + m.group(2), m.group(3) or m.group(4) or ""))
    return out


def parse_functions_md(md: str, names: set[str]) -> dict[str, tuple[str, str]]:
    """name → (signature, description), from the section headed with the name
    when there is one and from a bullet otherwise."""
    out: dict[str, tuple[str, str]] = {}
    for header, body in sections(md):
        headed = [n for n in re.findall(r"`(\w+)\(\)`", header) if n in names]
        paras = paragraphs(body)
        for name in headed:
            for para in paras:
                m = re.search(rf"`({re.escape(name)}\([^`]*\))`", para)
                if m:
                    out[name] = (m.group(1), describe(name, m.group(1), para))
                    break
            else:
                # "Same as `sort`, but sorts in descending order." — a section
                # that never spells the signature out; the paragraph still
                # describes it, and the signature comes from the parser.
                if paras and len(headed) == 1:
                    out[name] = ("", describe(name, "", paras[0]))
        for name, sig, text in bullets(body):
            if name in names and name not in out:
                out[name] = (sig, describe(name, sig, text))
    return out


def parse_aggregations(md: str) -> tuple[dict[str, tuple[str, str, bool]], str]:
    """name → (signature, description, experimental) from the aggregation
    operators section, plus the section's own syntax line — the indented
    `<aggr-op> [without|by (<label list>)] (…)` form."""
    for header, body in sections(md):
        if header.startswith("Aggregation operators"):
            out = {}
            for name, sig, text in bullets(body):
                experimental = "**experimental**" in text
                text = re.sub(r",\s*\*\*experimental\*\*.*$", "", text)
                out[name] = (sig, describe(name, sig, text), experimental)
            syntax = re.search(r"^ {4}(<aggr-op> .*)$", body, re.M)
            if not syntax:
                raise SystemExit("operators.md: no aggregation syntax line")
            return out, syntax.group(1).strip()
    raise SystemExit("operators.md: no 'Aggregation operators' section")


def lua_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    ref = sys.argv[1] if len(sys.argv) > 1 else REF
    functions = parse_functions_go(fetch(ref, "promql/parser/functions.go"))
    documented = parse_functions_md(fetch(ref, "docs/querying/functions.md"), set(functions))
    aggregations, syntax = parse_aggregations(fetch(ref, "docs/querying/operators.md"))

    entries = []
    for name in sorted(functions):
        spec = functions[name]
        sig, doc = documented.get(name, ("", ""))
        sig = sig or built_signature(name, spec)
        if not doc:
            print(f"undocumented: {name}", file=sys.stderr)
        entries.append((name, "function", sig, doc, spec["experimental"]))
    for name in sorted(aggregations):
        sig, doc, experimental = aggregations[name]
        entries.append((name, "aggregation", sig, doc, experimental))

    lines = [
        "--- PromQL built-in functions and aggregation operators, for completion",
        "--- and hover.",
        "---",
        f"--- GENERATED by scripts/gen_promql_builtins.py from prometheus/prometheus",
        f"--- at {ref}: promql/parser/functions.go (the function list, argument",
        "--- types, experimental flag), docs/querying/functions.md and",
        "--- docs/querying/operators.md (signatures and descriptions). Do not edit",
        "--- by hand; rerun the script to update.",
        "---",
        "--- @class PromqlBuiltin",
        '--- @field kind         "function"|"aggregation"',
        "--- @field signature    string   as the documentation writes it",
        "--- @field doc          string   one paragraph; empty when the docs say nothing",
        "--- @field experimental boolean  needs --enable-feature=promql-experimental-functions",
        "",
        "return {",
        "  --- How every aggregation operator is written, as operators.md states it.",
        f"  aggregation_syntax = {lua_string(syntax)},",
        "",
        "  --- @type table<string, PromqlBuiltin>",
        "  entries = {",
    ]
    for name, kind, sig, doc, experimental in entries:
        # `end` is a Lua keyword and a PromQL function; every key is quoted.
        lines.append(f"    [{lua_string(name)}] = {{")
        lines.append(f'      kind         = "{kind}",')
        lines.append(f"      signature    = {lua_string(sig)},")
        lines.append(f"      doc          = {lua_string(doc)},")
        lines.append(f"      experimental = {'true' if experimental else 'false'},")
        lines.append("    },")
    lines.append("  },")
    lines.append("}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT.relative_to(Path.cwd()) if OUT.is_relative_to(Path.cwd()) else OUT}: "
          f"{len(functions)} functions, {len(aggregations)} aggregations")


if __name__ == "__main__":
    main()
