<div align="center">

# vschema

**JSON Schema validation for V: documents get contracts, violations get answers.**

Targets [draft 2020-12](https://json-schema.org/specification-links#2020-12) ·
pure V · structured errors · zero C dependencies ·
measured, documented performance

[![draft](https://img.shields.io/badge/draft-2020--12-4a6b9e)](https://json-schema.org/draft/2020-12)
[![version](https://img.shields.io/badge/version-0.1.0-8a5f4a)](v.mod)
[![vpm](https://img.shields.io/badge/vpm-gil--silva.vschema-2b70a7)](https://vpm.vlang.io/packages/gil-silva.vschema)
[![license](https://img.shields.io/badge/license-MIT-3a8a5f)](#license)

*Stop arguing about JSON. Make the schema enforce it.*

</div>

---

## What is this, in three sentences?

JSON Schema is the standard vocabulary for describing what a JSON document may
contain — the same contracts that back OpenAPI documents, MCP tool
`inputSchema`s and validated configuration files. This module takes a schema
and, for any document, tells you **exactly which rules it violates, where in
the document and where in the schema** — as structured rows you can render,
filter or log, not a blunt `valid: false`. It is built for reuse on request
paths: parse a schema once per process and validate body after body with it —
concurrent requests included — with the measured numbers documented in
[Performance notes](#performance-notes).

## Install

```sh
# once the vpm listing lands: (pending submission)
v install gil-silva.vschema

# today: clone and use it as a module
git clone https://github.com/gil-silva/vschema
```

<details>
<summary><b>Using it locally in your own project?</b></summary>

Publishers resolve imports from `~/.vmodules`. A developer symlink mirrors the
installed layout:

```sh
ln -s /home/you/vlang/vschema ~/.vmodules/gil_silva/vschema
```

</details>

## The one-minute example

```v
import json2
import gil_silva.vschema.vschema

// parse the contract — malformed keywords fail loudly, right here
s := vschema.parse_schema_json('{"type": "integer", "minimum": 0, "maximum": 99}')!

// validate a document you already decoded — no re-parsing
doc := json2.parse('42', json2.DecoderOptions{})!
errors := s.validate(doc)
assert errors.len == 0
```

And what happens when it breaks:

```v
import gil_silva.vschema.vschema

s := vschema.parse_schema_json('{"type": "integer", "minimum": 0, "maximum": 99}')!
violations := s.validate_json('"not a number"') or { panic('malformed JSON: ${err.msg()}') }
for e in violations {
	println('${e.schema_path}: ${e.message}')
}
// /type: expected type "integer", got "string"
```

Values do not need to come from a file — anything you can express as a
`json2.Any` validates the same way:

```v
import json2
import gil_silva.vschema.vschema

s := vschema.parse_schema_json('{"type": "integer", "minimum": 0, "maximum": 99}')!
assert s.is_valid(json2.Any(42))
assert !s.is_valid(json2.Any('hello'))
```

The first assert holds (42 is an integer in range); the second does not.

## Structured rows, not a red blob

Every violation is a `VError` — data, not prose to guess at:

| field           | what it names               | example                                  |
| --------------- | --------------------------- | ---------------------------------------- |
| `instance_path` | JSON Pointer into the document | `""` (root), `"/user/name"` later     |
| `schema_path`   | JSON Pointer into the schema | `"/type"`, `"/maximum"`                 |
| `message`       | the violation itself        | `expected type "integer", got "string"`  |

Two properties worth knowing before you build on this:

- **Everything is collected.** Validation walks the implemented keywords in a
  fixed order and returns *all* violations in one pass — no
  stop-at-the-first-error surprises.
- **Deterministic.** Keyword order is fixed and map iteration never leaks into
  output, so the same input yields the same rows, every run.

## The API

| you want                                    | call                                        |
| ------------------------------------------- | ------------------------------------------- |
| parse a schema from raw JSON text           | `parse_schema_json(text string) !Schema`    |
| parse a schema already decoded with json2   | `parse_schema(value json2.Any) !Schema`     |
| derive a schema from a V struct, parsed     | `schema_of[T]() !Schema`                    |
| derive a schema from a V struct, as text    | `schema_json[T]() !string`                  |
| validate a decoded value                    | `(s Schema) validate(value json2.Any) []VError` |
| validate raw text; bad JSON is an error     | `(s Schema) validate_json(text string) ![]VError` |
| the boolean shortcut                        | `(s Schema) is_valid(value json2.Any) bool` |

`Schema` is the draft's two forms: `bool` (`true` accepts anything, `false`
rejects anything) or a decoded object schema (`SchemaNode`).

## Performance notes

Validation is built for reuse: parse a schema once per process, validate body
after body. A parsed `Schema` is read-only at validation time — nothing in it
is written while checks run — so one parse can serve concurrent requests
without locks. Everything request-shaped, pattern compilations included, is
per validation call: built when the walk needs it and released after, which is
also why no compiled regex is ever shared between calls (the matcher mutates
its state while running).

Rough numbers on the dev machine, mean over thousands of calls (μs/op): a flat
1 KB body walks in ~45 and a 95 KB body of 500 nested objects in ~11,500;
decoding those same bodies with `json2.parse` costs ~182 and ~46,000 — so
even on a body that large the walker is roughly a quarter of the round
trip, and decoding dominates. The keyword costs that scale with payload:
`uniqueItems`
deep-compares item pairs (quadratic, with an early exit on the first equal
pair), `contains` validates every item, and `pattern` compiles once per call
then reuses the compiled matcher for every matching position (all the keys of
a `propertyNames` object included).

## The parser is strict about schemas

A schema with a malformed keyword is a schema error, surfaced at parse time —
schema bugs should fail loudly, not wait for the first document:

```v
import gil_silva.vschema.vschema

_ = vschema.parse_schema_json('{"multipleOf": 0}') or {
	println('bad schema: ${err.msg()}')
	// multipleOf: must be strictly greater than 0
	return
}
```

The same applies to `maximum: "3"`, `minLength: -1`, `minLength: 2.5`,
`type: "banana"` and friends. Unknown keywords are **annotations** per the
draft and are simply skipped — forward-compatibility, not an error.

## References, recursion included

Schemas grow by naming parts of themselves: `#/$defs/<name>` fragment
pointers (RFC 6901 tokens, percent- and `~`-decoded), with `$defs` for the
named parts — including parts that describe themselves:

```v
import json2
import gil_silva.vschema.vschema

// a "node" contract built of nodes — one $defs entry, one $ref long
node := '{"type": "object", "properties": {"children":
	{"type": "array", "items": {"$ref": "#/$defs/node"}}}}'
s := vschema.parse_schema_json('{"$defs": {"node": ' + node + '}, "$ref": "#/$defs/node"}')!

bad := json2.parse('{"children": ["x"]}', json2.DecoderOptions{})!
rows := s.validate(bad)
assert rows.len == 1
assert rows[0].instance_path == '/children/0'
// the row re-points through the reference into the document: not a copy of
// the schema, a pointer into it
assert rows[0].schema_path == '/$defs/node/properties/children/items/$defs/node/type'
println('${rows[0].schema_path}: ${rows[0].message}')
```

The recursion is data-driven and terminates with the document's own shape; a
pointer that makes no progress (`"$ref": "#"` pointing at itself forever)
ends at a documented hop cap with a `/$ref` row, never a hang. External
references (`https://…`, other files) are rejected at parse time — an
in-document contract is what this crate validates, honest about what it does
not reach.

## Structs become schemas

MCP servers and typed APIs describe their payloads in V structs anyway — so
the schema can be written once, as the struct, and derived at compile time.
`schema_of[T]` derives and parses; `schema_json[T]` hands back the raw
document:

```v
import json2
import gil_silva.vschema.vschema

struct Tag {
	name string
	hits ?int
}

struct Note {
	text    string
	tags    []Tag
	created ?string @[json: 'made_at']
}

// derivation emits a full draft 2020-12 document: the root delegates to its
// own $defs entry, each reachable struct owns exactly one entry, structs are
// always referenced — and `created` sits outside `required` under its new name
doc := vschema.schema_json[Note]()!
assert doc.contains('"tags":{"type":"array","items":{"$ref":"#/$defs/Tag"}}')
assert doc.contains('"made_at":{"type":"string"}')
assert doc.contains('"required":["text","tags"]')

// validate right away — nothing else to set up
s := vschema.schema_of[Note]()!
assert s.is_valid(json2.parse('{"text":"ok","tags":[{"name":"x"}]}', json2.DecoderOptions{})!)
assert !s.is_valid(json2.parse('{"tags":[{"name":"x"}]}', json2.DecoderOptions{})!)
```

The mapping skews V-shaped: `int`/`u64`/… become `integer`, `f32`/`f64`
become `number`, arrays of anything become `"type":"array"` with `items`,
maps become `"type":"object"` with `additionalProperties`, enums keep their
integer values under `enum`, and struct-typed positions (fields, items,
additionalProperties) reference the struct's `$defs` entry — so a `Node`
containing `[]Node` is expressed with a self-`$ref` that the reference
machinery above already validates. Attributes complete the picture:
`@[json: 'x']` renames the property, `@[json: '-']`/`@[skip]` leave the field
out of the contract, `@[required]` pins an optional field into `required`.
Anything not JSON-mappable — pointers, sum types, embedded fields, unknown
scalar types — fails derivation with the field path named, loudly.

## What works today

| keyword       | note                                                                         |
| ------------- | ---------------------------------------------------------------------------- |
| boolean schemas | `true` / `false`                                                            |
| `type`        | one name or an array; `integer` = zero fractional part, so `1.0` counts       |
| `const` · `enum` | deep, kind-first equality: `false ≠ 0` yet `-2 == -2.0`; unordered objects |
| `maximum` `minimum` | inclusive boundaries, integers and floats alike                        |
| `exclusiveMaximum` `exclusiveMinimum` | exclusive; the boundary point is a violation           |
| `multipleOf`  | checked through `f64` with a bounded epsilon; overflows report honestly |
| `minLength` `maxLength` | Unicode code points (🇻 is one character, not four bytes)            |
| `pattern`     | substring semantics (`a+` matches inside `xxaayy`) via the stdlib `regex`     |
| `properties` `required` | per-property subschemas, with their own error paths below them |
| `items`       | one subschema for every element (the 2020-12 form); rows land at `/1`, `/2`…  |
| `propertyNames` | object keys validate as if they were the document                            |
| `min/maxProperties` · `min/maxItems` | structure-count bounds, integers and decimals alike      |
| `uniqueItems` | duplicates decided by the same deep, kind-first equality                      |
| `contains` `min/maxContains` | matching-item counts; `minContains: 0` allows zero matches      |
| `allOf` `anyOf` `oneOf` `not` | `allOf` reports per branch; disjunctions answer on the keyword |
| `$ref` `$defs` | fragment pointers (RFC 6901, `~`/`%`-decoded); rows re-point through refs |
| derivation (comptime) | `schema_of[T]()` — structs to contracts; scalars, arrays, maps, enums, options, `@[json:]`/`@[skip]`; cycles ride `$defs` |

<details>
<summary><b>Which groups are skipped, and why</b></summary>

- `pattern.json`'s group uses `\p{Letter}`, a Unicode property escape the V
  regex engine does not compile. Such patterns reach validation and surface as
  an explicit `/pattern` violation ("pattern is not supported by the V regex
  engine") instead of silently passing.
- Twenty-six of `ref.json`'s groups name `$id`-based addressing, which rides
  on scope-aware URI resolution — outside this milestone's fragment-pointer
  contract — and six reference remote URLs, skipped as `external reference`.
  The remaining skips lean on `prefixItems`, `additionalProperties`, `if`
  and `unevaluatedProperties`. Every skip names its own reason; nothing
  is faked.

</details>

## Conformance

Checked against the official
[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
(draft 2020-12 group files):

```
conformance: 609 passed, 0 failed, 39 groups skipped
skipped [ref.json group 15]: uses unimplemented keyword $id
skipped [defs.json group 0]: uses external reference
skipped [items.json group 5]: uses unimplemented keyword prefixItems
```

Run it yourself:

```sh
git clone --depth 1 https://github.com/json-schema-org/JSON-Schema-Test-Suite.git testsuite
cd vschema && v test .
```

Without the clone (it is gitignored, dev-only) the suite reports the skip and
passes; the inline unit tests carry the keyword behaviors regardless.

## Command line

The repository doubles as a CLI —

```sh
v -o bin/vschema .
./bin/vschema schema.json document.json
```

```text
$ ./bin/vschema schema.json document.json
valid                                            (exit 0)

$ ./bin/vschema schema.json bad.json
error at "" (/type): expected type "integer", got "string"   (exit 1)
```

No document? Then the schema itself is under test — a lint that reports
parse-time schema errors and nothing else:

```text
$ ./bin/vschema schema.json
schema ok                                        (exit 0)

$ ./bin/vschema bad_schema.json
vschema: schema: multipleOf: must be strictly greater than 0   (exit 1)
```

## Notes for the curious

- **Parse once, check many.** A parsed `Schema` is plain data — the same `s`
  validates one document or a million, with no per-document setup and no
  re-decoding between runs.
- **Pure V, no C.** Parsing rides on the standard `json2` module; `pattern`
  reuses the standard `regex` module. Nothing else is pulled in.
- **One number type.** Documents decoded by `json2` carry their numbers as
  `f64`, and so do schema keywords — comparisons are exact up to 2⁵³ and
  honest about rounding after that (see `multiple_of_rel_eps` in
  `validate.v`).
- **Kind-first equality.** `const: false` does not match `0`; `const: -2.0`
  matches `-2`. Type identity and mathematical value are separate questions,
  and the draft semantics require them separate — the conformance pair
  `9007199254740991` vs `.0`-suffixed data is exactly what settles it.
- **Structured errors end to end.** The same philosophy as V's own tooling:
  rows of data (path, rule, message), never a string to parse.
- **Each `$ref` binds once.** A fragment pointer's subschema parses exactly
  one time, however many `$ref`s name it; validation delegates through those
  bindings with a per-validation hop budget (128), so recursive `$defs`
  definitions cost nothing extra and unresolvable self-cycles answer with a
  `/$ref` row.

## FAQ

<details>
<summary><b>How is this different from json2?</b></summary>
`json2` is the codec: it parses and encodes JSON. This module sits on top of
it and adds the schema vocabulary — rules **about** the JSON (`required`,
bounds, patterns, types). They compose: decode with `json2`, validate with
`vschema`. One does not replace the other.
</details>

<details>
<summary><b>Is <code>"2.0"</code> a valid <code>minLength</code>?</b></summary>
Yes. Length bounds and the `integer` type accept integral-valued decimals —
`2.0` is the integer `2` — which is exactly what the official suite expects
from a 2020-12 validator.
</details>

<details>
<summary><b>Why does my <code>\p{...}</code> pattern fail?</b></summary>
The draft invokes ECMAScript regexes; V's `regex` module is close but partial.
Rather than being silently lenient, an uncompilable pattern becomes a
structured violation from the `/pattern` path — visible, loggable, never a
false pass.
</details>

<details>
<summary><b>Where is the vpm listing?</b></summary>
`gil-silva.vschema` is queued for submission; the badge links ahead of it.
Until it lands, the clone path above is the install.
</details>

## Roadmap

- **M2 — structure**: shipped — `properties`, `items`, `required`, `propertyNames`,
  counts, `uniqueItems`, `contains` (conformance 470/0/12 as of this release)
- **M3 — composition**: shipped — `allOf`, `anyOf`, `oneOf`, `not`
  (conformance 583/0/13 as of this release)
- **M4 — references**: shipped — `$ref` fragment pointers, `$defs`, parsed
  through a pointer memo with late binding; conformance 609/0/39 as of this
  release
- **M5 — the differentiator**: shipped — comptime derivation,
  `schema_of[T]()` / `schema_json[T]()`; struct closures become `$defs` +
  `$ref` contracts eaten directly by the validator above

## License

[MIT](LICENSE) — free to embed, fork and ship.
