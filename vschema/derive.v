// derive.v derives a draft 2020-12 schema document from a V struct type at
// compile time. Every struct in the type closure of `T` contributes one
// `#/$defs/<Short>` entry (Short is the last dot-segment of the fully
// qualified type name); struct-typed fields, including self-references,
// reference that entry, so recursive shapes fall out of the exact `$ref` /
// `$defs` machinery the parser already implements.
//
// The derived document is generated as JSON text and parsed through the
// ordinary parser, which keeps the derived schema's validation semantics
// byte-identical to schemas parsed from files.
//
// The field-to-keyword mapping mirrors V's JSON encoder family:
// - integers -> "type":"integer"; f32/f64 -> "type":"number";
//   string/bool map to themselves.
// - enums keep `"type":"integer"` plus their member values under "enum".
// - arrays (fixed or dynamic) become "type":"array" with "items".
// - maps become "type":"object" with "additionalProperties".
// - option fields produce their payload's schema and drop out of `required`.
// - `@[json: 'name']` renames the property, `@[json: '-']` and `@[skip]`
//   hide the field, `@[required]` keeps an optional field in `required`.
//
// Unsupported constructs (pointer, sum type, embedded fields, and any other
// non-JSON-mappable field type) fail derivation with an error naming the
// field path, so a half-derived schema never validates against a lie.
module vschema

// schema_of derives the schema of the struct type `T` through the ordinary
// parser, so `$ref` cycles bind the same way they do for parsed documents.
pub fn schema_of[T]() !Schema {
	text := schema_json[T]()!
	return parse_schema_json(text)
}

// schema_json derives the schema document of the struct type `T` as JSON
// text: `{"$ref":"#/$defs/<Root>","$defs":{...}}` — the root delegates to its
// own `$defs` entry, one per reachable struct in the closure, exactly once
// each. Non-struct `T` is an argument error.
pub fn schema_json[T]() !string {
	$if T is $struct {
		mut seen := []string{}
		mut order := []string{}
		mut defs := map[string]string{}
		_ := emit_any($zero(T), mut seen, mut order, mut defs)!
		root := short_name(typeof[T]().name)
		mut entries := []string{}
		for name in order {
			entries << escape_json(name) + ':' + defs[name]
		}
		return '{"$ref":"#/$defs/' + root + '","$defs":{' + entries.join(',') + '}}'
	}
	return error('schema_json: expected a struct type, got ${typeof[T]().name}')
}

// emit_any derives the schema fragment for the compile-time type carried by
// the value `v`. Struct types answer with a `{"$ref":"#/$defs/<Short>"}` to
// their one `$defs` entry, which is what makes self-referential types
// terminate. Recursion is value-based on purpose: generic calls pass
// `$zero(...)` or `v.$(field)` expressions whose types read at the call site,
// which this compiler shape monomorphizes reliably (passing `f.typ` directly
// does not compile here).
fn emit_any[T](v T, mut seen []string, mut order []string, mut defs map[string]string) !string {
	$if T is $struct {
		return emit_struct(v, mut seen, mut order, mut defs)
	} $else $if T is $option {
		return emit_any($zero(T.payload_type), mut seen, mut order, mut defs)
	} $else $if T is $array_dynamic {
		items := emit_any($zero(T.element_type), mut seen, mut order, mut defs)!
		return '{"type":"array","items":' + items + '}'
	} $else $if T is $array_fixed {
		items := emit_any($zero(T.element_type), mut seen, mut order, mut defs)!
		return '{"type":"array","items":' + items + '}'
	} $else $if T is $map {
		props := emit_any($zero(T.value_type), mut seen, mut order, mut defs)!
		return '{"type":"object","additionalProperties":' + props + '}'
	} $else $if T is $string {
		return '{"type":"string"}'
	} $else $if T is $enum {
		mut vals := []string{}
		$for m in T.values {
			vals << m.value.str()
		}
		return '{"type":"integer","enum":[' + vals.join(',') + ']}'
	} $else $if T is $int {
		return '{"type":"integer"}'
	} $else $if T is $float {
		return '{"type":"number"}'
	} $else $if T is bool {
		return '{"type":"boolean"}'
	}
	return error('schema_json: field type ${typeof(v).name} is not JSON-mappable')
}

// emit_struct derives the object schema of one struct visit. The first visit
// of a type claims its `$defs` spot and stores the full shape there; every
// visit (this one included) returns a `{"$ref":"#/$defs/<Short>"}`, so
// struct-valued fields, array items and map values are all ref-shaped and
// recursive types fall out of the cycle cut.
fn emit_struct[T](v T, mut seen []string, mut order []string, mut defs map[string]string) !string {
	name := short_name(typeof(v).name)
	if name in seen {
		return '{"$ref":"#/$defs/' + name + '"}'
	}
	// no defer here: a defer inside a comptime `$if` block pops immediately,
	// because the block is its scope. This branch has one exit point, so the
	// matching pop lives at the bottom.
	seen << name
	order << name
	mut props := []string{}
	mut reqs := []string{}
	$for f in T.fields {
		$if f.is_embed {
			return error('${name}.${f.name}: embedded fields are not supported by derivation')
		}
		// comptime `$for` unrolls entirely: skip-guard must be an `if`, since a
		// runtime `continue` here has no loop to continue.
		if !field_hidden(f.attrs) {
			key := field_key(f.attrs, f.name)
			$if f.indirections > 0 {
				return error('${name}.${f.name}: pointer fields (${typeof(f.typ).name}) are not supported by derivation')
			} $else $if f.typ is $sumtype {
				return error('${name}.${f.name}: sum type fields (${typeof(f.typ).name}) are not supported by derivation')
			} $else $if f.typ is $option {
				inner := emit_any($zero(f.typ.payload_type), mut seen, mut order, mut defs)!
				props << escape_json(key) + ':' + inner
				if field_required(f.attrs) {
					reqs << escape_json(key)
				}
			} $else $if f.unaliased_typ is $array_dynamic {
				items := emit_any(v.$(f.name), mut seen, mut order, mut defs)!
				props << escape_json(key) + ':' + items
				reqs << escape_json(key)
			} $else $if f.unaliased_typ is $array_fixed {
				items := emit_any(v.$(f.name), mut seen, mut order, mut defs)!
				props << escape_json(key) + ':' + items
				reqs << escape_json(key)
			} $else $if f.unaliased_typ is $map {
				sub := emit_any(v.$(f.name), mut seen, mut order, mut defs)!
				props << escape_json(key) + ':' + sub
				reqs << escape_json(key)
			} $else $if f.typ is $struct {
				inner := emit_any(v.$(f.name), mut seen, mut order, mut defs)!
				props << escape_json(key) + ':' + inner
				reqs << escape_json(key)
			} $else $if f.typ is $enum {
				sub := emit_any($zero(f.typ), mut seen, mut order, mut defs)!
				props << escape_json(key) + ':' + sub
				reqs << escape_json(key)
			} $else $if f.typ is $int {
				props << escape_json(key) + ':{"type":"integer"}'
				reqs << escape_json(key)
			} $else $if f.typ is $float {
				props << escape_json(key) + ':{"type":"number"}'
				reqs << escape_json(key)
			} $else $if f.typ is string {
				props << escape_json(key) + ':{"type":"string"}'
				reqs << escape_json(key)
			} $else $if f.typ is bool {
				props << escape_json(key) + ':{"type":"boolean"}'
				reqs << escape_json(key)
			} $else {
				return error('${name}.${f.name}: field type ${typeof(f.typ).name} is not supported by derivation')
			}
		}
	}
	mut shape := '{"type":"object"'
	if props.len > 0 {
		shape += ',"properties":{' + props.join(',') + '}'
	}
	if reqs.len > 0 {
		shape += ',"required":[' + reqs.join(',') + ']'
	}
	shape += '}'
	defs[name] = shape
	seen.pop()
	// even the first visit answers with the ref: the full shape lives in its
	// defs entry, so every use of the struct points the same way
	return '{"$ref":"#/$defs/' + name + '"}'
}

// short_name reduces a qualified type name to its own segment: the key used
// for `$defs` and `$ref` targets alike. Two structs with equal short names in
// different namespaces would collide; that is a documented derivation limit.
fn short_name(full string) string {
	return full.split('.').last()
}

// field_key resolves the property name for a field: `@[json: 'name']` wins,
// otherwise the V field name. Quote forms mirror the stdlib attribute parser.
fn field_key(attrs []string, def string) string {
	for attr in attrs {
		if attr.starts_with('json:') {
			rest := attr[5..].trim_space()
			if rest.len > 1 && (rest[0] == `'` || rest[0] == `"`) && rest[rest.len - 1] == rest[0] {
				return rest[1..rest.len - 1]
			}
			if rest != '-' {
				return rest
			}
		}
	}
	return def
}

// field_hidden reports `@[json: '-']` / `@[skip]`: the property cannot appear
// in instance data, so derivation leaves it out of `properties` and
// `required`.
fn field_hidden(attrs []string) bool {
	for attr in attrs {
		if attr == 'skip' {
			return true
		}
		if attr.starts_with('json:') {
			rest := attr[5..].trim_space()
			if rest.len > 1 && (rest[0] == `'` || rest[0] == `"`) && rest[rest.len - 1] == rest[0] {
				if rest[1..rest.len - 1] == '-' {
					return true
				}
			} else if rest == '-' {
				return true
			}
		}
	}
	return false
}

// field_required honors `@[required]`: an option field still lands in the
// `required` array.
fn field_required(attrs []string) bool {
	return attrs.contains('required')
}

// escape_json quotes a string for direct splicing into the derived document.
// Control characters below 0x20 get the five short escapes or a \uXXXX form;
// everything else is expected to be valid UTF-8 and passes through.
fn escape_json(s string) string {
	mut out := '"'
	for c in s {
		match c {
			`\\` {
				out += '\\\\'
			}
			`"` {
				out += '\\"'
			}
			`\n` {
				out += '\\n'
			}
			`\r` {
				out += '\\r'
			}
			`\t` {
				out += '\\t'
			}
			else {
				if c < 0x20 {
					out += '\\u${c:04x}'
				} else {
					out += c.ascii_str()
				}
			}
		}
	}
	out += '"'
	return out
}
