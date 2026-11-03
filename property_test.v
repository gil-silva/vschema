// property_test.v seeds the checks a fixed-vector test cannot state:
// generated junk never panics the parser or the validator, and documents
// sampled by hypo.gen_of(T) validate clean against schema_of(T). The
// derivation and the validator walk the same comptime field metadata, so
// any drift between them lands here as a failing seed and a minimal
// counterexample instead of as a silent lie. hypo (vpm: gil-silva.hypo)
// supplies the seeded runner — a failing seed replays identically through
// VHYPO_SEED. Documents are encoded with enum_as_int, the option the
// "type":"integer" enum schema sets; the enum regression pins the ordinal
// document directly.
module vschema

import hypo
import json2

// the tested types. Option fields are declared mut because the derivation
// writes them.
enum Mode {
	off
	auto
	full
}

// the enum-ordinal regression: this file exists partly because `enum` used
// to derive the member NAMES — "enum":[off,auto,full] — text no schema
// parser accepts.
struct Dimmer {
	mode Mode
}

// every keyword mapping the derivation implements, nested struct, enum and
// optionality included.
struct Note {
	ink string
mut:
	weight ?f64
}

struct Receipt {
	order int
	label string
	mode  Mode
	flag  bool
	mass  f64
mut:
	price  ?f64
	mates  []string
	scores map[string]int
	note   Note
}

// arbitrary junk must parse without panic: failures stay errors.
struct ParseNeverPanics {}

fn (_ ParseNeverPanics) holds(text string) bool {
	parsed := parse_schema_json(text) or { return true }
	_ = parsed
	return true
}

// the same for validate_json on arbitrary text over a real schema.
struct DocNeverPanics {
	schema Schema
}

fn (p DocNeverPanics) holds(text string) bool {
	errs := p.schema.validate_json(text) or { return true }
	_ = errs
	return true
}

// the property under test: a documented sample — hypo draws it, json2
// encodes it, the validator must accept it.
struct DocsFitTheirSchema {
	schema Schema
}

fn (p DocsFitTheirSchema) holds(doc Receipt) bool {
	text := json2.encode(doc, enum_as_int: true)
	errs := p.schema.validate_json(text) or { return false }
	return errs.len == 0
}

fn test_generated_junk_never_panics_the_parser() {
	res := hypo.check_with_seed(hypo.string_gen(0, 80), ParseNeverPanics{}, 7)
	assert res.passed
}

fn test_generated_junk_never_panics_the_validator() {
	schema := parse_schema_json('{"type":"integer"}')!
	res := hypo.check_with_seed(hypo.string_gen(0, 80), DocNeverPanics{ schema: schema }, 7)
	assert res.passed
}

fn test_schema_json_pins_enum_ordinals() {
	doc := schema_json[Dimmer]()!
	assert doc.contains('"mode":{"type":"integer","enum":[0,1,2]}')
	assert doc.contains('"required":["mode"]')
}

fn test_generated_documents_fit_their_derived_schema() {
	res := hypo.check_with_seed(hypo.gen_of(Receipt{}), DocsFitTheirSchema{ schema: schema_of[Receipt]()! }, 42)
	assert res.passed
}
