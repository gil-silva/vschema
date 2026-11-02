// Conformance harness over the official json-schema-org/JSON-Schema-Test-Suite
// (draft 2020-12 group files).
//
// The suite is a dev-only clone (an ordinary `git clone` of the repository)
// expected under <repo root>/testsuite/. It is gitignored, so a fresh clone
// of vschema has no coverage from this file — it reports the skip loudly and
// passes. When the clone exists, every group of the covered files is applied:
// the group schema is parsed and each of its tests' data is validated, and
// the expected `valid` flag must match. Groups whose schema uses keywords not
// yet implemented (as of this milestone: everything but type / const / enum /
// numeric bounds / multipleOf / string lengths / pattern) or whose pattern
// the V regex engine cannot compile are skipped and counted in the summary.
module vschema

import json2
import os
import regex

// conformance_files are the draft 2020-12 group files covered by the
// implemented keywords (see module doc).
const conformance_files = [
	'boolean_schema.json'
	'type.json'
	'const.json'
	'enum.json'
	'multipleOf.json'
	'maximum.json'
	'minimum.json'
	'exclusiveMaximum.json'
	'exclusiveMinimum.json'
	'maxLength.json'
	'minLength.json'
	'pattern.json',
]

// unimplemented_keywords are the schema-semantic keywords outside this
// milestone: a group schema carrying any of them cannot be answered
// fully-correctly yet, so the group is skipped and counted. Annotations
// ($schema, $comment, default...) and implemented keywords do not appear.
const unimplemented_keywords = [
	'$anchor'
	'$defs'
	'$dynamicAnchor'
	'$dynamicRef'
	'$id'
	'$ref'
	'additionalItems'
	'additionalProperties'
	'allOf'
	'anyOf'
	'contains'
	'dependentRequired'
	'dependentSchemas'
	'if'
	'items'
	'maxContains'
	'maxItems'
	'maxProperties'
	'minContains'
	'minItems'
	'minProperties'
	'not'
	'oneOf'
	'prefixItems'
	'properties'
	'propertyNames'
	'required'
	'then'
	'uniqueItems'
	'unevaluatedProperties'
	'else',
]

// suite_root is the dev-only clone location, relative to the repo root
// (the nearest v.mod above this module directory).
fn suite_root() string {
	return os.join_path(@VMODROOT, 'testsuite')
}

// test_conformance_m1_groups runs the whole covered corpus; a single test
// failure is printed with its described case before the boolean assertion.
fn test_conformance_m1_groups() {
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
			s := parse_schema(raw_schema) or {
				panic('${file} group ${gi}: suite schema failed to parse: ${err.msg()}')
			}
			if reason := group_skip_reason(g) {
				skipped_groups++
				eprintln('skipped [${file} group ${gi}]: ${reason}')
				continue
			}
			for ti, tarr in (g['tests'] or { json2.Null{} }).as_array() {
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

// group_skip_reason reports why a group cannot be answered correctly yet: an
// unimplemented keyword at the schema's top level (subschema-carrying
// keywords cannot hide an unimplemented constraint in this milestone), or a
// pattern that fails to compile under the V regex engine.
fn group_skip_reason(g map[string]json2.Any) ?string {
	raw_schema := g['schema'] or { return none }
	if !(raw_schema is map[string]json2.Any) {
		return none
	}
	sm := raw_schema as map[string]json2.Any
	for k, _ in sm {
		if k in unimplemented_keywords {
			return 'uses unimplemented keyword ${k}'
		}
	}
	if raw := sm['pattern'] {
		if raw is string {
			_ = regex.regex_opt(raw as string) or {
				return 'pattern does not compile under the V regex engine'
			}
		}
	}
	return none
}
