// schema.v declares the draft 2020-12 schema model and parses schemas out of
// `json2.Any` trees. Boolean schemas stay `bool`; object schemas are decoded
// into a `SchemaNode` where every familiar keyword becomes a field. Unknown
// keywords are annotations and skipped, per the draft.
module vschema

import json2
import math

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
// keywords with the wrong value type are reported as errors.
pub fn parse_schema(a json2.Any) !Schema {
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
				node.properties = parse_properties(v) or { return err }
			}
			'required' {
				node.required = parse_required(v) or { return err }
			}
			'propertyNames' {
				pn := parse_schema_value(v, k) or { return err }
				node.property_names = &pn
			}
			'items' {
				it_s := parse_schema_value(v, k) or { return err }
				node.items = &it_s
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
				co := parse_schema_value(v, k) or { return err }
				node.contains = &co
			}
			'minContains' {
				node.min_contains = parse_length(v, k) or { return err }
			}
			'maxContains' {
				node.max_contains = parse_length(v, k) or { return err }
			}
			'allOf' {
				node.all_of = parse_schema_array(v, k) or { return err }
			}
			'anyOf' {
				node.any_of = parse_schema_array(v, k) or { return err }
			}
			'oneOf' {
				node.one_of = parse_schema_array(v, k) or { return err }
			}
			'not' {
				n := parse_schema_value(v, k) or { return err }
				node.not = &n
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
	n := parse_number(v, 'multipleOf') or { return err }
	if n <= 0.0 {
		return error('multipleOf: must be strictly greater than 0')
	}
	return n
}

// parse_length converts a string keyword bound: a non-negative integer, with
// integral decimals like `2.0` accepted as `2` per the conformance suite.
fn parse_length(v json2.Any, name string) !i64 {
	if !is_num(v) {
		return error('${name}: must be a non-negative integer')
	}
	n := num_value(v)
	if !is_math_integer(n) || n < 0.0 {
		return error('${name}: must be a non-negative integer')
	}
	return i64(n)
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
fn parse_schema_value(v json2.Any, name string) !Schema {
	if v is bool {
		return Schema(v)
	}
	if is_map_schema(v) {
		return parse_schema(v)
	}
	return error('${name}: must be a boolean or an object schema')
}

// parse_properties converts the `properties` keyword: an object mapping
// property names to schemas, each parsed recursively. Subschemas are held by
// reference so the node tree may nest arbitrarily without value cycles.
fn parse_properties(v json2.Any) !map[string]&Schema {
	if !is_map_schema(v) {
		return error('properties: must be an object')
	}
	mut out := map[string]&Schema{}
	for pk, pv in v as map[string]json2.Any {
		ps := parse_schema(pv) or { return err }
		out[pk] = &ps
	}
	return out
}

// parse_required converts the `required` keyword: an array of property names.
fn parse_required(v json2.Any) ![]string {
	if !(v is []json2.Any) {
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
fn parse_schema_array(v json2.Any, name string) ![]&Schema {
	if !(v is []json2.Any) {
		return error('${name}: must be an array of schemas')
	}
	mut out := []&Schema{}
	for item in v as []json2.Any {
		s := parse_schema_value(item, name) or { return err }
		out << &s
	}
	return out
}
