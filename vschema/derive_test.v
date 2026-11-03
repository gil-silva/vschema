// derive_test.v covers struct-to-schema derivation: the comptime field walk,
// the attribute handling (json rename, skip, required, optionality), the
// cyclic `$defs` shape, and the loud rejections (pointer, sum type, embed,
// non-struct root).
module vschema

import json2

struct Day {
	name string
	bd   ?int @[json: 'b_day']
}

struct Task {
	line   string
	level  int
	rate   f64
	flag   bool
	tag    Day
	mates  []string
	scores map[string]int
}

struct Node {
	name string
	kids []Node
}

// Forced: `must` is optional but flagged required; `rest` stays optional.
struct Forced {
	must ?string @[required]
	rest ?int
}

// Skipped: `hidden` never shows up in the derived document.
struct Skipped {
	seen   string
	hidden ?string @[skip]
}

// Wrapper embeds Day anonymously; embedding is a documented derivation limit.
struct Wrapper {
	Day
}

type Tag = int | string

struct BadSum {
	t Tag
}

struct BadPtr {
	parent &Task = unsafe { nil }
}

fn test_derive_scalars_and_containers() {
	doc := schema_json[Task]()!
	// every scalar maps to its JSON type
	assert doc.contains('"line":{"type":"string"}')
	assert doc.contains('"level":{"type":"integer"}')
	assert doc.contains('"rate":{"type":"number"}')
	assert doc.contains('"flag":{"type":"boolean"}')
	// arrays carry their items schema, maps their additionalProperties schema
	assert doc.contains('"mates":{"type":"array","items":{"type":"string"}}')
	assert doc.contains('"scores":{"type":"object","additionalProperties":{"type":"integer"}}')
	// struct-typed fields always reference their one defs entry
	assert doc.contains('"tag":{"$ref":"#/$defs/Day"}')
	// names take their V field form; renamed JSON keys win over field names
	assert doc.contains('"name":{"type":"string"}')
	assert !doc.contains('"bd":')
	// non-option fields are required, option fields are not
	assert doc.contains('"required":["line","level","rate","flag","tag","mates","scores"]')
	assert doc.contains('"required":["name"]')
	// one def per reachable struct, first-visit order, root first
	assert doc.contains('"$defs":{"Task":{"type":"object"')
	assert doc.contains(',"Day":{"type":"object"')
}

fn test_derive_nested_shape() {
	doc := schema_json[Task]()!
	// the Day entry lives once, under $defs, listing only required fields
	nested := '"Day":{"type":"object","properties":' +
		'{"name":{"type":"string"},"b_day":{"type":"integer"}},"required":["name"]}'
	assert doc.contains(nested)
}

fn test_derive_attrs() {
	doc_forced := schema_json[Forced]()!
	assert doc_forced.contains('"must":{"type":"string"}')
	assert doc_forced.contains('"rest":{"type":"integer"}')
	// `@[required]` pushes the optional field into required; bare options stay out
	assert doc_forced.contains('"required":["must"]')
	assert !doc_forced.contains('"required":["must","rest"]')
	// hidden fields vanish entirely
	doc_skip := schema_json[Skipped]()!
	assert doc_skip.contains('"seen":{"type":"string"}')
	assert !doc_skip.contains('"hidden')
}

fn test_derive_cycle_roundtrip() {
	doc := schema_json[Node]()!
	// root inlines the shape once; the self-referential items collapse to a ref
	assert doc.contains('"kids":{"type":"array","items":{"$ref":"#/$defs/Node"}}')
	assert doc.contains('"required":["name","kids"]')
	assert doc.contains('"$defs":{"Node":{"type":"object"')
	// no second Node entry: the closure registers the type exactly once
	assert !doc.contains(',"Node":{')
	schema := schema_of[Node]()!
	// a recursive instance whose every level satisfies the shape validates clean
	good :=
		json2.parse('{"name":"root","kids":[{"name":"a","kids":[]},{"name":"b","kids":[]}]}', json2.DecoderOptions{})!
	assert schema.validate(good).len == 0
	// a child missing its own required `kids` fails on the derived schema
	bad := json2.parse('{"name":"root","kids":[{"name":"a"}]}', json2.DecoderOptions{})!
	errs := schema.validate(bad)
	assert errs.len > 0
	// the M4 ref delegation reports schema paths through the ref targets: the
	// root ref itself hops first, then the kids/items ref
	assert errs[0].schema_path == '/$defs/Node/properties/kids/items/$defs/Node/required'
}

// derive_err_of turns a derivation into its error message; a `!` that does not
// fire returns a marker string, which makes the contains-assertions fail
// loudly for wrongly-accepted types.
fn derive_err_of[T]() string {
	str := schema_json[T]() or { return err.msg() }
	_ = str
	return 'UNEXPECTED-derivation-success'
}

fn test_derive_rejects() {
	sum_err := derive_err_of[BadSum]()
	assert sum_err.contains('BadSum.t')
	assert sum_err.contains('sum type')
	ptr_err := derive_err_of[BadPtr]()
	assert ptr_err.contains('BadPtr.parent')
	embed_err := derive_err_of[Wrapper]()
	assert embed_err.contains('Wrapper')
	assert embed_err.contains('embedded')
	root_err := derive_err_of[int]()
	assert root_err.contains('expected a struct type')
}

fn test_escape_json() {
	assert escape_json('plain') == '"plain"'
	assert escape_json('a"b') == '"a\\"b"'
	assert escape_json('a\\b') == '"a\\\\b"'
	assert escape_json('a\nb\tc\rd') == '"a\\nb\\tc\\rd"'
	// a control character escapes as \uXXXX
	assert escape_json(u8(1).ascii_str()) == '"\\u0001"'
	// non-ASCII UTF-8 passes through untouched
	assert escape_json('汉') == '"汉"'
}
