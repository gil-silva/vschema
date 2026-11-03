// Conformance harness over the official json-schema-org/JSON-Schema-Test-Suite
// (draft 2020-12 group files).
//
// The suite is a dev-only clone (an ordinary `git clone` of the repository)
// expected under <repo root>/testsuite/. It is gitignored, so a fresh clone
// of vschema has no coverage from this file — it reports the skip loudly and
// passes. When the clone exists, every group of the covered files is applied:
// the group schema is parsed and each of its tests' data is validated, and
// the expected `valid` flag must match. Groups whose schema uses keywords
// outside the implemented set (`unimplemented_keywords` below) or whose
// pattern the V regex engine cannot compile are skipped and counted in the
// summary.
module vschema

import json2
import os
import regex

// conformance_files are the draft 2020-12 group files covered by the
// implemented keywords (see module doc).
const conformance_files = [
	'boolean_schema.json',
	'type.json',
	'const.json',
	'enum.json',
	'multipleOf.json',
	'maximum.json',
	'minimum.json',
	'exclusiveMaximum.json',
	'exclusiveMinimum.json',
	'maxLength.json',
	'minLength.json',
	'pattern.json',
	'properties.json',
	'required.json',
	'propertyNames.json',
	'items.json',
	'minProperties.json',
	'maxProperties.json',
	'minItems.json',
	'maxItems.json',
	'uniqueItems.json',
	'contains.json',
	'minContains.json',
	'maxContains.json',
	'allOf.json',
	'anyOf.json',
	'oneOf.json',
	'not.json',
	'defs.json',
	'ref.json',
]

// unimplemented_keywords are the schema-semantic keywords outside this
// milestone: a group schema carrying any of them cannot be answered
// fully-correctly yet, so the group is skipped and counted. Annotations
// ($schema, $comment, default...) and implemented keywords do not appear.
const unimplemented_keywords = [
	'$anchor',
	'$dynamicAnchor',
	'$dynamicRef',
	'$id',
	'additionalItems',
	'additionalProperties',
	'dependentRequired',
	'dependentSchemas',
	'if',
	'prefixItems',
	'then',
	'else',
	'unevaluatedItems',
	'unevaluatedProperties',
]

// data_keywords carry plain data, not schemas: their values must never be
// walked for keywords, and their nested maps are instance values (an enum
// with object entries is data, not subschema vocabulary).
const data_keywords = ['const', 'enum', 'examples', 'default']

// suite_root is the dev-only clone location, relative to the repo root
// (the nearest v.mod above this module directory).
fn suite_root() string {
	return os.join_path(@VMODROOT, 'testsuite')
}

// test_conformance_groups runs the whole covered corpus; a single test
// failure is printed with its described case before the boolean assertion.
fn test_conformance_groups() {
	base := os.join_path(suite_root(), 'tests', 'draft2020-12')
	if !os.exists(base) {
		eprintln('conformance_test: testsuite/ absent (dev-only clone of json-schema-org/JSON-Schema-Test-Suite) — nothing to check')
		return
	}
	mut passed := 0
	mut failed := 0
	mut skipped_groups := 0
	for file in conformance_files {
		raw := os.read_file(os.join_path(base, file)) or {
			eprintln('conformance_test: missing ${file} in the clone — skipping file')
			continue
		}
		groups := json2.parse(raw, json2.DecoderOptions{}) or {
			panic('${file}: the official suite file does not parse: ${err.msg()}')
		}
		for gi, garr in groups.as_array() {
			g := garr.as_map()
			raw_schema := g['schema'] or { json2.Null{} }
			// the skip decision runs before parsing on purpose: groups using
			// refs the validator does not implement (remote URLs, $id-based
			// pointers) fail to parse by design and must be skipped, not paniced
			if reason := group_skip_reason(g) {
				skipped_groups++
				eprintln('skipped [${file} group ${gi}]: ${reason}')
				continue
			}
			s := parse_schema(raw_schema) or {
				panic('${file} group ${gi}: suite schema failed to parse: ${err.msg()}')
			}
			raw_tests := g['tests'] or { json2.Null{} }
			for ti, tarr in raw_tests.as_array() {
				t := tarr.as_map()
				mut t_description := ''
				if d := t['description'] {
					t_description = d.str()
				}
				data := t['data'] or { json2.Null{} }
				mut want := false
				if w := t['valid'] {
					want = w.bool()
				}
				got := s.validate(data)
				got_valid := got.len == 0
				if got_valid == want {
					passed++
					continue
				}
				failed++
				eprintln('FAIL [${file} group ${gi} test ${ti}] ${t_description}')
				for e in got {
					eprintln('   -> ${e.schema_path}: ${e.message}')
				}
			}
		}
	}
	eprintln('conformance: ${passed} passed, ${failed} failed, ${skipped_groups} groups skipped')
	assert failed == 0
}

// group_skip_reason reports why a group cannot be answered correctly yet:
// any unimplemented keyword anywhere in the group's schema tree (data
// positions such as enum/const are not walked), or any pattern at any depth
// that fails to compile under the V regex engine.
fn group_skip_reason(g map[string]json2.Any) ?string {
	raw_schema := g['schema'] or { return none }
	if raw_schema !is map[string]json2.Any {
		return none
	}
	return schema_skip_reason(raw_schema as map[string]json2.Any)
}

// schema_skip_reason walks a schema tree keyword by keyword; subschema
// positions are recursed so a constraint cannot hide under implemented
// structure (a pattern under properties, an anyOf nested inside items...).
fn schema_skip_reason(sm map[string]json2.Any) ?string {
	for k, v in sm {
		if k in unimplemented_keywords {
			return 'uses unimplemented keyword ${k}'
		}
		if k == '$ref' {
			// a reference leaving this document (URL, URN, other file) cannot
			// be answered — resolution is fragment-pointers only this release
			if v is string && !((v as string).starts_with('#')) {
				return 'uses external reference'
			}
		}
		if k == 'pattern' {
			if v is string {
				_ = regex.regex_opt(v as string) or {
					return 'pattern does not compile under the V regex engine'
				}
			}
		}
		if k in data_keywords {
			continue
		}
		if v is map[string]json2.Any {
			m := v as map[string]json2.Any
			if r := schema_skip_reason(m) {
				return r
			}
		}
		if v is []json2.Any {
			for item in v as []json2.Any {
				if item is map[string]json2.Any {
					im := item as map[string]json2.Any
					if r := schema_skip_reason(im) {
						return r
					}
				}
			}
		}
	}
	return none
}
