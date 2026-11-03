// schema.v declares the draft 2020-12 schema model and parses schemas out of
// `json2.Any` trees. Boolean schemas stay `bool`; object schemas are decoded
// into a `SchemaNode` where every familiar keyword becomes a field. Unknown
// keywords are annotations and skipped, per the draft.
module vschema

import json2
import math

// Pending holds one late-bound `$ref` target: while a pointer's subschema is
// still being parsed, referencing nodes hold its Pending; the moment that
// parse finishes, `target` is bound and every holder reads the same bound
// schema, which is how recursive `$ref`s reach a fixed point at parse time.
// The target is stored by value, not as a reference: a pointer would make
// every read a tag-fragile dereference of an option field written during
// parsing.
struct Pending {
mut:
	target ?Schema
}

// ResCtx threads one schema document through recursive parsing: the raw
// document stays available for `$ref` pointer resolution, and per-pointer
// state (memo cache, in-flight marks, late-binding waiters) keeps resolution
// parse-once and cycle-safe.
struct ResCtx {
	root json2.Any
mut:
	in_flight map[string]bool
	pending   map[string][]&Pending
	cache     map[string]&Pending
}

// Schema is either a boolean schema (trivially accepts or rejects everything)
// or an object schema decoded into SchemaNode.
pub type Schema = bool | SchemaNode

// SchemaNode holds the draft 2020-12 keywords implemented so far, in their
// optional form. Numbers keep their f64 representation from json2; string
// length bounds are stored as i64 after being validated as non-negative
// integers (a decimal like `2.0` is accepted as the integer `2`).
pub struct SchemaNode {
pub mut:
	typ            ?[]string
	const_value    ?json2.Any
	enum_value     ?[]json2.Any
	maximum        ?f64
	minimum        ?f64
	exclusive_max  ?f64
	exclusive_min  ?f64
	multiple_of    ?f64
	min_length     ?i64
	max_length     ?i64
	pattern        ?string
	properties     ?map[string]&Schema
	prop_keys      ?[]string
	required       ?[]string
	property_names ?&Schema
	items          ?&Schema
	min_properties ?i64
	max_properties ?i64
	min_items      ?i64
	max_items      ?i64
	unique_items   ?bool
	contains       ?&Schema
	min_contains   ?i64
	max_contains   ?i64
	all_of         ?[]&Schema
	any_of         ?[]&Schema
	one_of         ?[]&Schema
	not            ?&Schema
	raw_ref        ?string
	ref_binding    ?&Pending
	defs           ?map[string]&Schema
}

// is_num reports whether the Any carries a JSON number variant.
fn is_num(a json2.Any) bool {
	return a is f64 || a is f32 || a is int || a is i8 || a is i16 || a is i32 || a is i64
		|| a is u8 || a is u16 || a is u32 || a is u64
}

// is_map_schema reports whether the Any is a schema object.
fn is_map_schema(a json2.Any) bool {
	return a is map[string]json2.Any
}

// num_value extracts the numeric value of a number Any as f64. Anything that
// is not a number yields 0; call is_num first when the distinction matters.
fn num_value(a json2.Any) f64 {
	if a is f64 { return a }
	if a is f32 { return f64(a) }
	if a is int { return f64(a) }
	if a is i8 { return f64(a) }
	if a is i16 { return f64(a) }
	if a is i32 { return f64(a) }
	if a is i64 { return f64(a) }
	if a is u8 { return f64(a) }
	if a is u16 { return f64(a) }
	if a is u32 { return f64(a) }
	if a is u64 { return f64(a) }
	return 0.0
}

// is_math_integer reports whether a numeric value has no fractional part.
// This is what the `integer` type means in draft 2020-12: `1.0` and `1`
// alike. Non-finite values are never integers.
fn is_math_integer(v f64) bool {
	return !math.is_inf(v, 0) && !math.is_nan(v) && v == math.trunc(v)
}

// parse_schema parses a schema tree from a decoded `json2.Any` value:
// booleans become boolean schemas, objects become SchemaNodes, anything else
// is a malformed schema. Unknown keywords are skipped as annotations; known
// keywords with the wrong value type are reported as errors. `$ref`
// fragment pointers resolve against the tree itself.
pub fn parse_schema(a json2.Any) !Schema {
	mut ctx := &ResCtx{
		root: a
	}
	// the root itself goes through the resolver as pointer "#" so any
	// "$ref": "#" inside the document late-binds to the root instead of
	// re-parsing the whole schema forever
	pend := resolve_pointer(mut ctx, '#') or { return err }
	return pend.target or { return error('the root schema resolved through a pending reference') }
}

// parse_schema_ctx is the recursive parser; ctx carries the document root so
// `$ref` pointers resolve against the whole document, not the subschema.
fn parse_schema_ctx(a json2.Any, mut ctx &ResCtx) !Schema {
	if a is bool {
		return Schema(a)
	}
	if !is_map_schema(a) {
		return error('a schema must be a boolean or an object')
	}
	m := a as map[string]json2.Any
	mut node := SchemaNode{}
	for k, v in m {
		match k {
			'type' {
				node.typ = parse_type(v) or { return err }
			}
			'const' {
				node.const_value = v
			}
			'enum' {
				node.enum_value = parse_enum(v) or { return err }
			}
			'maximum' {
				node.maximum = parse_number(v, k) or { return err }
			}
			'minimum' {
				node.minimum = parse_number(v, k) or { return err }
			}
			'exclusiveMaximum' {
				node.exclusive_max = parse_number(v, k) or { return err }
			}
			'exclusiveMinimum' {
				node.exclusive_min = parse_number(v, k) or { return err }
			}
			'multipleOf' {
				node.multiple_of = parse_multiple_of(v) or { return err }
			}
			'minLength' {
				node.min_length = parse_length(v, k) or { return err }
			}
			'maxLength' {
				node.max_length = parse_length(v, k) or { return err }
			}
			'pattern' {
				node.pattern = parse_pattern(v) or { return err }
			}
			'properties' {
				props := parse_properties(v, mut ctx) or { return err }
				// prop_keys carries the parse-time sorted key list; the
				// validator walks instance objects in this order instead
				// of re-sorting the keys once per object
				mut sorted := props.keys()
				sorted.sort()
				node.properties = props
				node.prop_keys = sorted
			}
			'required' {
				node.required = parse_required(v) or { return err }
			}
			'propertyNames' {
				name_schema := parse_schema_value(v, k, mut ctx) or { return err }
				node.property_names = &name_schema
			}
			'items' {
				item_schema := parse_schema_value(v, k, mut ctx) or { return err }
				node.items = &item_schema
			}
			'minProperties' {
				node.min_properties = parse_length(v, k) or { return err }
			}
			'maxProperties' {
				node.max_properties = parse_length(v, k) or { return err }
			}
			'minItems' {
				node.min_items = parse_length(v, k) or { return err }
			}
			'maxItems' {
				node.max_items = parse_length(v, k) or { return err }
			}
			'uniqueItems' {
				node.unique_items = parse_bool_keyword(v, k) or { return err }
			}
			'contains' {
				sub := parse_schema_value(v, k, mut ctx) or { return err }
				node.contains = &sub
			}
			'minContains' {
				node.min_contains = parse_length(v, k) or { return err }
			}
			'maxContains' {
				node.max_contains = parse_length(v, k) or { return err }
			}
			'allOf' {
				node.all_of = parse_schema_array(v, k, mut ctx) or { return err }
			}
			'anyOf' {
				node.any_of = parse_schema_array(v, k, mut ctx) or { return err }
			}
			'oneOf' {
				node.one_of = parse_schema_array(v, k, mut ctx) or { return err }
			}
			'not' {
				negated := parse_schema_value(v, k, mut ctx) or { return err }
				node.not = &negated
			}
			'$ref' {
				if v !is string {
					return error('${k}: must be a string')
				}
				raw := v as string
				bind := resolve_pointer(mut ctx, raw) or { return err }
				node.raw_ref = raw
				node.ref_binding = bind
			}
			'$defs' {
				node.defs = parse_defs(v, mut ctx) or { return err }
			}
			else {
				// annotations and keywords not implemented on this release
			}
		}
	}
	return Schema(node)
}

// parse_schema_json parses a schema from raw JSON text.
pub fn parse_schema_json(text string) !Schema {
	parsed := json2.parse(text, json2.DecoderOptions{}) or {
		return error('invalid schema JSON: ${err.msg()}')
	}
	return parse_schema(parsed)
}

// parse_type converts the `type` keyword: either a single type name or an
// array of them. Only the seven draft names are accepted.
fn parse_type(v json2.Any) ![]string {
	mut names := []string{}
	mut bad := false
	if v is string {
		names << v
	} else if v is []json2.Any {
		for item in v {
			if item is string {
				names << item
			} else {
				bad = true
			}
		}
	} else {
		bad = true
	}
	if bad {
		return error('type: must be a string or an array of strings')
	}
	for name in names {
		if name !in ['null', 'boolean', 'object', 'array', 'number', 'string', 'integer'] {
			return error('type: ${name} is not a known type')
		}
	}
	return names
}

// parse_enum converts the `enum` keyword: an array of any values (an empty
// array is a schema that rejects everything).
fn parse_enum(v json2.Any) ![]json2.Any {
	if v is []json2.Any {
		return v
	}
	return error('enum: must be an array')
}

// parse_number extracts a strictly numeric keyword value.
fn parse_number(v json2.Any, name string) !f64 {
	if is_num(v) {
		return num_value(v)
	}
	return error('${name}: must be a number')
}

// parse_multiple_of validates the multipleOf value: any positive number.
fn parse_multiple_of(v json2.Any) !f64 {
	modulus := parse_number(v, 'multipleOf') or { return err }
	if modulus <= 0.0 {
		return error('multipleOf: must be strictly greater than 0')
	}
	return modulus
}

// parse_length converts a string keyword bound: a non-negative integer, with
// integral decimals like `2.0` accepted as `2` per the conformance suite.
fn parse_length(v json2.Any, name string) !i64 {
	if !is_num(v) {
		return error('${name}: must be a non-negative integer')
	}
	bound := num_value(v)
	if !is_math_integer(bound) || bound < 0.0 {
		return error('${name}: must be a non-negative integer')
	}
	return i64(bound)
}

// parse_pattern validates that the pattern keyword is a string. Compilation
// happens at validation time, where a pattern the V regex engine cannot
// handle is reported as a structured error.
fn parse_pattern(v json2.Any) !string {
	if v is string {
		return v
	}
	return error('pattern: must be a string')
}

// parse_schema_value converts a schema-carrying keyword value (`items`,
// `contains`, `propertyNames`): a boolean schema or a nested object schema
// (which is parsed recursively, so its own errors surface at parse time).
fn parse_schema_value(v json2.Any, name string, mut ctx &ResCtx) !Schema {
	if v is bool {
		return Schema(v)
	}
	if is_map_schema(v) {
		return parse_schema_ctx(v, mut ctx)
	}
	return error('${name}: must be a boolean or an object schema')
}

// parse_properties converts the `properties` keyword: an object mapping
// property names to schemas, each parsed recursively. Subschemas are held by
// reference so the node tree may nest arbitrarily without value cycles.
fn parse_properties(v json2.Any, mut ctx &ResCtx) !map[string]&Schema {
	if !is_map_schema(v) {
		return error('properties: must be an object')
	}
	mut out := map[string]&Schema{}
	for key, raw in v as map[string]json2.Any {
		parsed := parse_schema_ctx(raw, mut ctx) or { return err }
		out[key] = &parsed
	}
	return out
}

// parse_required converts the `required` keyword: an array of property names.
fn parse_required(v json2.Any) ![]string {
	if v !is []json2.Any {
		return error('required: must be an array of strings')
	}
	mut names := []string{}
	for item in v as []json2.Any {
		if item is string {
			names << item
		} else {
			return error('required: must be an array of strings')
		}
	}
	return names
}

// parse_bool_keyword converts a boolean-valued keyword such as `uniqueItems`.
fn parse_bool_keyword(v json2.Any, name string) !bool {
	if v is bool {
		return v
	}
	return error('${name}: must be a boolean')
}

// parse_schema_array converts a composition keyword (`allOf`, `anyOf`,
// `oneOf`): an array of subschemas, each parsed recursively. An empty array
// is legal — the draft's "allOf: [] defines zero constraints" group — so the
// parser never rejects it.
fn parse_schema_array(v json2.Any, name string, mut ctx &ResCtx) ![]&Schema {
	if v !is []json2.Any {
		return error('${name}: must be an array of schemas')
	}
	mut out := []&Schema{}
	for item in v as []json2.Any {
		parsed := parse_schema_value(item, name, mut ctx) or { return err }
		out << &parsed
	}
	return out
}

// parse_defs converts the `$defs` keyword: entries parse through the pointer
// memo (`#/$defs/<name>`), so a sibling `$ref` and the entry share one parse.
// An entry whose target is still in flight (the container pointing at
// itself, "empty tokens" style) stays out of the map: `$defs` exists as a
// lookup surface, validation goes through the refs themselves, which bind
// late anyway.
fn parse_defs(v json2.Any, mut ctx &ResCtx) !map[string]&Schema {
	if !is_map_schema(v) {
		return error('$defs: must be an object')
	}
	mut out := map[string]&Schema{}
	for name, _ in v as map[string]json2.Any {
		pend := resolve_pointer(mut ctx, '#/$defs' + pointer_token(name)) or { return err }
		bound := pend.target or { continue }
		out[name] = &bound
	}
	return out
}

// resolve_pointer resolves a document-fragment reference — either `#` (the
// root) or `#/a/b` (a JSON Pointer into the document) — against the raw
// document tree. Resolution is memoized per pointer, and a pointer currently
// being parsed returns a Pending that binds once its parse completes, which
// is how recursive `$ref`s reach a fixed point at parse time. Anything that
// is not a fragment of this document is unsupported and fails loudly.
fn resolve_pointer(mut ctx &ResCtx, frag string) !&Pending {
	if !frag.starts_with('#') {
		return error('$ref: external references are not supported — only in-document "#..." pointers')
	}
	if pend := ctx.cache[frag] {
		return pend
	}
	if ctx.in_flight[frag] {
		pending := &Pending{}
		mut waiters := ctx.pending[frag] or { []&Pending{} }
		waiters << pending
		ctx.pending[frag] = waiters
		return pending
	}
	ctx.in_flight[frag] = true
	target := pointer_walk(ctx, frag[1..]) or {
		ctx.in_flight.delete(frag)
		return err
	}
	parsed := parse_schema_ctx(target, mut ctx) or {
		ctx.in_flight.delete(frag)
		return err
	}
	bound := &Pending{
		target: parsed
	}
	ctx.cache[frag] = bound
	// late-bind every reference that arrived while this pointer was parsing
	for mut waiter in ctx.pending[frag] or { []&Pending{} } {
		waiter.target = parsed
	}
	ctx.pending.delete(frag)
	ctx.in_flight.delete(frag)
	return bound
}

// pointer_uri_decode decodes RFC 3986 percent-escapes in a fragment pointer:
// every %XX pair becomes its byte value; malformed pairs or lone "%"
// characters pass through unchanged. Decoding runs before tokenization so
// "#/$defs/percent%25field" names the property "percent%field" (the draft's
// $ref value is a URI reference whose fragment carries the pointer).
fn pointer_uri_decode(s string) string {
	if !s.contains('%') {
		return s
	}
	raw := s.bytes()
	mut out := []u8{}
	mut i := 0
	for i < raw.len {
		if raw[i] == 37 && i + 2 < raw.len {
			hi := hex_digit(raw[i + 1])
			lo := hex_digit(raw[i + 2])
			if hi >= 0 && lo >= 0 {
				out << u8(hi * 16 + lo)
				i += 3
				continue
			}
		}
		out << raw[i]
		i++
	}
	return out.bytestr()
}

// hex_digit maps one hexadecimal character to its nibble value, or -1.
fn hex_digit(b u8) int {
	if 48 <= b && b <= 57 {
		return int(b) - 48
	}
	if 97 <= b && b <= 102 {
		return int(b) - 87
	}
	if 65 <= b && b <= 70 {
		return int(b) - 55
	}
	return -1
}

// pointer_walk follows a JSON Pointer (already without its '#') through the
// document tree; the leading slash of "#/a/b" opens the document relative
// root and is not itself a token (`#` alone is the document). Percent
// escapes decode first, then `~0` / `~1` unescape per token in the RFC 6901
// order, and array elements are chosen by index.
fn pointer_walk(ctx &ResCtx, pointer string) !json2.Any {
	if pointer == '' {
		return ctx.root
	}
	mut cur := ctx.root
	rel := if pointer.starts_with('/') { pointer[1..] } else { pointer }
	decoded := pointer_uri_decode(rel)
	for token in decoded.split('/') {
		key := token.replace('~1', '/').replace('~0', '~')
		cur = pointer_down(cur, key) or { return error('$ref: cannot resolve "#${pointer}"') }
	}
	return cur
}

// pointer_down descends one pointer token: into an array only by index, into
// an object by key; anything else has no such position.
fn pointer_down(cur json2.Any, key string) ?json2.Any {
	if cur is []json2.Any {
		arr := cur as []json2.Any
		// a hand-rolled digit check: string.int() non-option returns zero
		// for garbage, which would alias index 0 instead of failing loudly
		digits := '0123456789'
		for c in key {
			if !digits.contains(c.ascii_str()) {
				return none
			}
		}
		if key == '' {
			return none
		}
		idx := key.int()
		if idx < 0 || idx >= arr.len {
			return none
		}
		return arr[idx]
	}
	if cur is map[string]json2.Any {
		m := cur as map[string]json2.Any
		return m[key] or { return none }
	}
	return none
}
