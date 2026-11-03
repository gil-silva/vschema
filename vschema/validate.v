// validate.v applies a Schema to a json2.Any instance and collects every
// violation as a structured row: where the instance failed
// (VError.instance_path, a JSON Pointer), which part of the schema produced
// the rule (VError.schema_path) and why (VError.message).
module vschema

import json2
import math
import regex

// VError is one validation violation, structured so callers can render or
// filter it without string parsing.
pub struct VError {
pub mut:
	instance_path string
	schema_path   string
	message       string
}

// multiple_of_rel_eps bounds the relative gap around an integer quotient that
// still counts as a multiple. Float division rounds the true quotient: the
// conformance suite requires `12391239123` to be a multiple of `1e-08` (the
// exact quotient carries more bits than f64) while `0.00751` must not be a
// multiple of `0.0001` (a 5% remainder). 1e-12 sits between the two with room
// to spare.
const multiple_of_rel_eps = 1e-12

// max_ref_hops bounds $ref delegation chains. Ordinary documents terminate
// at their own data depth long before the cap; the guard exists for
// no-progress self-reference cycles ("$ref": "#" delegating to the very
// schema that delegates) which consume no data depth and would otherwise
// dispatch forever. A chain that outlasts the budget yields /$ref rows
// instead of a hang. The number is also the maximum $ref-recursion stack
// depth (three frames per hop), so it stays modest.
const max_ref_hops = 128

// PatternCache memoizes regex compilations within one validation call. The
// same pattern reaches the matcher once per matching position — every key of
// a propertyNames object, every matching item of an array — and recompiling
// a regex per position dominated those walks. The cache exists per call:
// validation runs synchronously inside one call, so the compiled matchers
// here are only ever touched by the thread running the call, and a `Schema`
// stays safe to reuse from concurrent requests.
struct PatternCache {
mut:
	compiled map[string]regex.RE
	failed   map[string]bool
}

// validate applies the schema to an instance and returns every violation;
// an empty slice means the instance is valid.
pub fn (s Schema) validate(input json2.Any) []VError {
	// the pattern memo is per call: validation walks synchronously and never
	// shares matchers across calls, so a parsed Schema stays safe to reuse
	// from concurrent requests
	mut pc := &PatternCache{}
	return s.validate_bounded(input, max_ref_hops, mut pc)
}

// validate_bounded applies the schema with `hops` reference delegations
// still budgeted; every $ref step consumes one from its own share, so a
// data-driven recursion (each nesting level = one hop) runs as deep as the
// instance while a no-progress cycle stops at the guard. `pc` memoizes
// pattern compilations for the whole call.
fn (s Schema) validate_bounded(input json2.Any, hops int, mut pc &PatternCache) []VError {
	if s is bool {
		if !s {
			return [
				VError{
					schema_path: ''
					message:     'the schema is false and rejects this instance'
				},
			]
		}
		return []
	}
	// the only remaining variant after the boolean check above
	return (s as SchemaNode).validate_node(input, hops, mut pc)
}

// validate_json validates raw JSON text, reporting malformed JSON as a result
// error rather than a schema violation.
pub fn (s Schema) validate_json(text string) ![]VError {
	parsed := json2.parse(text, json2.DecoderOptions{}) or {
		return error('invalid JSON: ${err.msg()}')
	}
	return s.validate(parsed)
}

// is_valid answers the boolean form of the validation question.
pub fn (s Schema) is_valid(input json2.Any) bool {
	return s.validate(input).len == 0
}

// validate_node walks the implemented keywords in a fixed order, collecting
// all violations instead of short-circuiting on the first. Object-specific
// and array-specific keywords only apply to instances of their kind, but a
// type mismatch is still reported alongside any other violated keyword.
fn (s SchemaNode) validate_node(input json2.Any, hops int, mut pc &PatternCache) []VError {
	mut errs := []VError{}
	if typ := s.typ {
		mut matched := false
		for name in typ {
			if type_matches(name, input) {
				matched = true
			}
		}
		if !matched {
			// one name reads as "the type", several as "one of the types"
			wanted := typ.map('"${it}"').join(', ')
			verb := if typ.len == 1 { 'type' } else { 'one of types' }
			errs << VError{
				schema_path: '/type'
				message:     'expected ${verb} ${wanted}, got "${kind_name(input)}"'
			}
		}
	}
	if const_val := s.const_value {
		if !deep_equal(input, const_val) {
			errs << VError{
				schema_path: '/const'
				message:     'value must equal the const value'
			}
		}
	}
	if enum_val := s.enum_value {
		mut matched := false
		for candidate in enum_val {
			if deep_equal(input, candidate) {
				matched = true
			}
		}
		if !matched {
			errs << VError{
				schema_path: '/enum'
				message:     'value must be one of the enum values'
			}
		}
	}
	if max := s.maximum {
		if is_num(input) {
			n := num_value(input)
			if n > max {
				errs << VError{
					schema_path: '/maximum'
					message:     'value is above the maximum of ${max}'
				}
			}
		}
	}
	if min := s.minimum {
		if is_num(input) {
			n := num_value(input)
			if n < min {
				errs << VError{
					schema_path: '/minimum'
					message:     'value is below the minimum of ${min}'
				}
			}
		}
	}
	if cap := s.exclusive_max {
		if is_num(input) {
			n := num_value(input)
			if n >= cap {
				errs << VError{
					schema_path: '/exclusiveMaximum'
					message:     'value must be below the exclusive maximum of ${cap}'
				}
			}
		}
	}
	if floor := s.exclusive_min {
		if is_num(input) {
			n := num_value(input)
			if n <= floor {
				errs << VError{
					schema_path: '/exclusiveMinimum'
					message:     'value must be above the exclusive minimum of ${floor}'
				}
			}
		}
	}
	if modulus := s.multiple_of {
		if is_num(input) {
			n := num_value(input)
			if !is_multiple_of(n, modulus) {
				errs << VError{
					schema_path: '/multipleOf'
					message:     'value is not a multiple of ${modulus}'
				}
			}
		}
	}
	if input is string {
		text := input as string
		if min_len := s.min_length {
			if text.runes().len < min_len {
				errs << VError{
					schema_path: '/minLength'
					message:     'string is shorter than ${min_len} characters'
				}
			}
		}
		if max_len := s.max_length {
			if text.runes().len > max_len {
				errs << VError{
					schema_path: '/maxLength'
					message:     'string is longer than ${max_len} characters'
				}
			}
		}
		if pat := s.pattern {
			if row := pattern_error(pat, text, mut pc) {
				errs << row
			}
		}
	}
	if input is map[string]json2.Any {
		obj := input as map[string]json2.Any
		errs << s.object_violations(obj, hops, mut pc)
	}
	if input is []json2.Any {
		arr := input as []json2.Any
		errs << s.array_violations(arr, hops, mut pc)
	}
	errs << s.composition_violations(input, hops, mut pc)
	errs << s.ref_violations(input, hops, mut pc)
	return errs
}

// composition_violations answers allOf / anyOf / oneOf / not: keywords that
// apply to the instance whatever its kind. allOf collects every branch's rows
// (every branch is mandatory); the disjunctive keywords report a single row
// on the keyword itself — which branch failed is branch ordering, not a
// per-document path, so a keyword-level row keeps output deterministic.
fn (s SchemaNode) composition_violations(input json2.Any, hops int, mut pc &PatternCache) []VError {
	mut errs := []VError{}
	if branches := s.all_of {
		for bi, bptr in branches {
			branch := *bptr
			for e in branch.validate_bounded(input, hops, mut pc) {
				mut row := e
				row.schema_path = '/allOf${pointer_token(bi.str())}${e.schema_path}'
				errs << row
			}
		}
	}
	if branches := s.any_of {
		mut found := false
		for bptr in branches {
			branch := *bptr
			if branch.validate_bounded(input, hops, mut pc).len == 0 {
				found = true
			}
		}
		if !found {
			errs << VError{
				schema_path: '/anyOf'
				message:     'no anyOf subschema matched'
			}
		}
	}
	if branches := s.one_of {
		mut matches := 0
		for bptr in branches {
			branch := *bptr
			if branch.validate_bounded(input, hops, mut pc).len == 0 {
				matches++
			}
		}
		if matches == 0 {
			errs << VError{
				schema_path: '/oneOf'
				message:     'no oneOf subschema matched'
			}
		} else if matches > 1 {
			errs << VError{
				schema_path: '/oneOf'
				message:     'value matches ${matches} oneOf subschemas, exactly one is required'
			}
		}
	}
	if not_ptr := s.not {
		negated := *not_ptr
		if negated.validate_bounded(input, hops, mut pc).len == 0 {
			errs << VError{
				schema_path: '/not'
				message:     'value must not match the not subschema'
			}
		}
	}
	return errs
}

// ref_violations delegates the $ref keyword to its bound target. In draft
// 2020-12 a reference is not exclusive, so the target's rows join whatever
// sibling keywords produced; rows re-point into the document: the fragment
// (minus "#") prefixes the target's schema paths — "#/$defs/int" reports
// "/$defs/int/type", and "#" (the root) leaves target paths unchanged. The
// delegation spends one hop of the recursion budget; a chain that spends
// more than the cap stops with a single /$ref guard row.
fn (s SchemaNode) ref_violations(input json2.Any, hops int, mut pc &PatternCache) []VError {
	raw := s.raw_ref or { return []VError{} }
	bind := s.ref_binding or { return []VError{} }
	if hops <= 0 {
		return [
			VError{
				schema_path: '/$ref'
				message:     'reference delegation exceeded the ${max_ref_hops}-hop recursion guard'
			},
		]
	}
	target := bind.target or { return []VError{} }
	mut errs := []VError{}
	for e in target.validate_bounded(input, hops - 1, mut pc) {
		mut row := e
		row.schema_path = raw[1..] + e.schema_path
		errs << row
	}
	return errs
}

// object_violations applies the object keywords in fixed order: required,
// propertyNames (the keys validate as strings), properties (each present
// property validates against its subschema), then the property-count bounds.
// Keys are ordered by the parse-computed sorted list, so map iteration never
// leaks into output.
fn (s SchemaNode) object_violations(obj map[string]json2.Any, hops int, mut pc &PatternCache) []VError {
	mut errs := []VError{}
	if req := s.required {
		for key in req {
			if key !in obj {
				errs << VError{
					schema_path: '/required'
					message:     'required property "${key}" is missing'
				}
			}
		}
	}
	if names_ptr := s.property_names {
		name_schema := *names_ptr
		mut keys := obj.keys()
		keys.sort()
		for key in keys {
			for e in name_schema.validate_bounded(json2.Any(key), hops, mut pc) {
				mut row := e
				row.instance_path = pointer_token(key)
				row.schema_path = '/propertyNames${e.schema_path}'
				errs << row
			}
		}
	}
	// properties and prop_keys hold together: prop_keys is the sorted key
	// order of the properties map, computed once at parse time
	if props := s.properties {
		if sorted_names := s.prop_keys {
			for name in sorted_names {
				sub_ptr := props[name] or { continue }
				sub := *sub_ptr
				prop_val := obj[name] or { continue }
				for e in sub.validate_bounded(prop_val, hops, mut pc) {
					mut row := e
					row.instance_path = pointer_token(name) + e.instance_path
					row.schema_path = '/properties${pointer_token(name)}${e.schema_path}'
					errs << row
				}
			}
		}
	}
	if min_p := s.min_properties {
		if obj.len < int(min_p) {
			errs << VError{
				schema_path: '/minProperties'
				message:     'object has fewer than ${min_p} properties'
			}
		}
	}
	if max_p := s.max_properties {
		if obj.len > int(max_p) {
			errs << VError{
				schema_path: '/maxProperties'
				message:     'object has more than ${max_p} properties'
			}
		}
	}
	return errs
}

// array_violations applies the array keywords in fixed order: items (every
// item validates as a prefix-free subschema), item-count bounds, uniqueness
// under deep equality, and contains with its optional match-count bounds.
fn (s SchemaNode) array_violations(arr []json2.Any, hops int, mut pc &PatternCache) []VError {
	mut errs := []VError{}
	if items_ptr := s.items {
		item_schema := *items_ptr
		for i, item in arr {
			for e in item_schema.validate_bounded(item, hops, mut pc) {
				mut row := e
				row.instance_path = pointer_token(i.str()) + e.instance_path
				// the same subschema speaks for every index, so the pointer
				// stays at /items (properties, by contrast, selects per name)
				row.schema_path = '/items${e.schema_path}'
				errs << row
			}
		}
	}
	if min_i := s.min_items {
		if arr.len < int(min_i) {
			errs << VError{
				schema_path: '/minItems'
				message:     'array has fewer than ${min_i} items'
			}
		}
	}
	if max_i := s.max_items {
		if arr.len > int(max_i) {
			errs << VError{
				schema_path: '/maxItems'
				message:     'array has more than ${max_i} items'
			}
		}
	}
	if uniq := s.unique_items {
		if uniq && array_not_unique(arr) {
			errs << VError{
				schema_path: '/uniqueItems'
				message:     'array items are not unique'
			}
		}
	}
	if contains_ptr := s.contains {
		sub := *contains_ptr
		errs << s.contains_violations(arr, sub, hops, mut pc)
	}
	return errs
}

// contains_violations answers the contains question: how many items match.
// The match floor is max(1, minContains), and maxContains bounds the count
// above. When fewer matches than the floor, the row points at /minContains
// whenever minContains raised the floor, or at /contains on the plain form.
fn (s SchemaNode) contains_violations(arr []json2.Any, contains_schema Schema, hops int, mut pc &PatternCache) []VError {
	mut matches := 0
	for item in arr {
		if contains_schema.validate_bounded(item, hops, mut pc).len == 0 {
			matches++
		}
	}
	// minContains lowers the required count when explicitly given (a value of
	// 0 makes even zero matches valid); absent means the floor of 1.
	mut floor := 1
	if min_count := s.min_contains {
		floor = int(min_count)
	}
	if matches < floor {
		if min_count := s.min_contains {
			return [
				VError{
					schema_path: '/minContains'
					message:     'only ${matches} array item(s) match the contains schema, fewer than ${min_count}'
				},
			]
		}
		return [
			VError{
				schema_path: '/contains'
				message:     'no array item matches the contains schema'
			},
		]
	}
	if max_count := s.max_contains {
		if matches > int(max_count) {
			return [
				VError{
					schema_path: '/maxContains'
					message:     'more array item(s) match the contains schema (${matches}) than the maximum of ${max_count}'
				},
			]
		}
	}
	return []
}

// pointer_token renders one JSON Pointer reference token: the "~" and "/"
// characters of a property name or item index are escape sequences per the
// pointer spec (`~0`, `~1`), and the token is returned with its leading slash.
fn pointer_token(name string) string {
	return '/' + name.replace('~', '~0').replace('/', '~1')
}

// array_not_unique reports whether any pair of items compares equal under
// the kind-first deep equality used throughout validation.
fn array_not_unique(arr []json2.Any) bool {
	for i := 0; i < arr.len; i++ {
		for j := i + 1; j < arr.len; j++ {
			if deep_equal(arr[i], arr[j]) {
				return true
			}
		}
	}
	return false
}

// is_multiple_of checks `n % d == 0` through the float path: the quotient is
// accepted when it is an integer (possibly after harmless rounding, absorbed
// by the relative epsilon) and rejected when the quotient diverges, which
// happens for overflow combinations like `1e308 / 0.123456789`.
fn is_multiple_of(n f64, d f64) bool {
	q := n / d
	if math.is_inf(q, 0) {
		return false
	}
	mut scale := math.abs(q)
	if scale < 1.0 {
		scale = 1.0
	}
	frac := math.abs(q - math.trunc(q))
	return frac <= multiple_of_rel_eps * scale
}

// unsupported_pattern_row is the structured violation for a pattern the V
// regex engine cannot compile.
fn unsupported_pattern_row(pattern string) VError {
	return VError{
		schema_path: '/pattern'
		message:     'pattern is not supported by the V regex engine: ${pattern}'
	}
}

// pattern_error returns none when the pattern matches. A pattern the V regex
// engine cannot compile (the draft asks for ECMAScript regexes; V is
// close-but-partial) becomes a structured violation rather than a silent
// non-match, and an unanchored non-match becomes the plain violation. The
// compile and the compile-failure are both memoized in `pc` for the call.
fn pattern_error(pattern string, text string, mut pc &PatternCache) ?VError {
	if pc.failed[pattern] {
		return unsupported_pattern_row(pattern)
	}
	if cached := pc.compiled[pattern] {
		return find_row(cached, text)
	}
	re := regex.regex_opt(pattern) or {
		pc.failed[pattern] = true
		return unsupported_pattern_row(pattern)
	}
	pc.compiled[pattern] = re
	return find_row(re, text)
}

// find_row applies a compiled matcher to one instance string. `find` mutates
// its own working state, so the matcher always runs on a per-invocation
// copy; the cached entry is never handed around.
fn find_row(re regex.RE, text string) ?VError {
	mut rc := re
	start, _ := rc.find(text)
	if start == regex.no_match_found {
		return VError{
			schema_path: '/pattern'
			message:     'string does not match the pattern'
		}
	}
	return none
}

// kind_name names the JSON kind of an instance value, using the seven
// draft type names. `integer` collapses into `number` for messaging.
fn kind_name(a json2.Any) string {
	if a is json2.Null {
		return 'null'
	}
	if a is bool {
		return 'boolean'
	}
	if is_num(a) {
		return 'number'
	}
	if a is string {
		return 'string'
	}
	if a is []json2.Any {
		return 'array'
	}
	if a is map[string]json2.Any {
		return 'object'
	}
	return 'unknown'
}

// type_matches applies one draft type name to an instance value.
fn type_matches(name string, a json2.Any) bool {
	match name {
		'null' {
			return a is json2.Null
		}
		'boolean' {
			return a is bool
		}
		'string' {
			return a is string
		}
		'array' {
			return a is []json2.Any
		}
		'object' {
			return a is map[string]json2.Any
		}
		'number' {
			return is_num(a)
		}
		'integer' {
			return is_num(a) && is_math_integer(num_value(a))
		}
		else {
			return false
		}
	}
}

// deep_equal compares two JSON values under field-value semantics: booleans
// know nothing of numbers, numbers compare by mathematical value (`-2` and
// `-2.0` are equal), objects are unordered key/value sets, arrays are ordered.
fn deep_equal(a json2.Any, b json2.Any) bool {
	if is_bool(a) != is_bool(b) {
		return false
	}
	if is_bool(a) {
		return bool_value(a) == bool_value(b)
	}
	if a is json2.Null || b is json2.Null {
		return a is json2.Null && b is json2.Null
	}
	if a is string || b is string {
		if !(a is string && b is string) {
			return false
		}
		return a == b
	}
	if is_num(a) != is_num(b) {
		return false
	}
	if is_num(a) {
		return num_value(a) == num_value(b)
	}
	if a is []json2.Any && b is []json2.Any {
		aa := a as []json2.Any
		bb := b as []json2.Any
		if aa.len != bb.len {
			return false
		}
		for i, item in aa {
			if !deep_equal(item, bb[i]) {
				return false
			}
		}
		return true
	}
	if a is map[string]json2.Any && b is map[string]json2.Any {
		am := a as map[string]json2.Any
		bm := b as map[string]json2.Any
		if am.len != bm.len {
			return false
		}
		for k, v in am {
			if bv := bm[k] {
				if !deep_equal(v, bv) {
					return false
				}
			} else {
				return false
			}
		}
		return true
	}
	return false
}

// is_bool reports whether the Any carries a boolean.
fn is_bool(a json2.Any) bool {
	return a is bool
}

// bool_value extracts the boolean of a bool Any.
fn bool_value(a json2.Any) bool {
	if a is bool {
		return a
	}
	return false
}
