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
	typ           ?[]string
	const_value   ?json2.Any
	enum_value    ?[]json2.Any
	maximum       ?f64
	minimum       ?f64
	exclusive_max ?f64
	exclusive_min ?f64
	multiple_of   ?f64
	min_length    ?i64
	max_length    ?i64
	pattern       ?string
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
