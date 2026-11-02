// Inline unit tests for schema parsing and draft 2020-12 keyword validation.
module vschema

import json2

// val parses a JSON text into an Any, panicking on malformed fixtures.
fn val(text string) json2.Any {
	return json2.parse(text, json2.DecoderOptions{}) or { panic('fixture: ${err.msg()}') }
}

// schema builds a Schema from raw JSON text, panicking on parser errors.
fn schema(text string) Schema {
	return parse_schema_json(text) or { panic('schema: ${err.msg()}') }
}

// rejects reports whether a raw schema text fails to parse.
fn rejects(text string) bool {
	s := parse_schema_json(text) or { return true }
	_ = s
	return false
}

// errs_texts maps violations to their messages for assertions.
fn err_texts(errors []VError) string {
	return errors.map(it.message).join('; ')
}

fn test_boolean_schemas() {
	assert schema('true').is_valid(val('1'))
	assert schema('true').is_valid(val('{"a": 1}'))
	f := schema('false')
	assert f.is_valid(val('true')) == false
	errors := f.validate(val('42'))
	assert errors.len == 1
	assert errors[0].schema_path == ''
	assert errors[0].instance_path == ''
	assert errors[0].message.contains('false')
}

fn test_parse_rejects_non_schemas() {
	assert rejects('"hello"')
	assert rejects('3')
	assert rejects('[]')
	assert rejects('null')
}

fn test_parse_unknown_keywords_are_annotations() {
	s := schema('{"$schema": "https://json-schema.org/draft/2020-12/schema", "$comment": "note", "type": "string"}')
	assert s.is_valid(val('"x"'))
	assert !s.is_valid(val('1'))
}

fn test_parse_errors_report_malformed_keywords() {
	assert rejects('{"maximum": "3"}')
	assert rejects('{"minimum": {}}')
	assert rejects('{"exclusiveMaximum": "3"}')
	assert rejects('{"multipleOf": 0}')
	assert rejects('{"multipleOf": "2"}')
	assert rejects('{"type": 5}')
	assert rejects('{"type": "banana"}')
	assert rejects('{"type": ["string", 5]}')
	assert rejects('{"enum": {}}')
	assert rejects('{"minLength": -1}')
	assert rejects('{"minLength": "2"}')
	assert rejects('{"maxLength": 2.5}')
	assert rejects('{"pattern": 5}')
}

fn test_type_keyword() {
	assert schema('{"type": "string"}').is_valid(val('"hi"'))
	assert !schema('{"type": "string"}').is_valid(val('1'))
	// a string that looks like a number is still a string
	assert schema('{"type": "string"}').is_valid(val('"1"'))
	// an empty string is still a string
	assert schema('{"type": "string"}').is_valid(val('""'))
}

fn test_type_string_with_lookalike_number() {
	// a float is not a string, but "1.0" as text is
	assert schema('{"type": "string"}').is_valid(val('"1.0"'))
}

fn test_type_array_of_names() {
	s := schema('{"type": ["string", "number"]}')
	assert s.is_valid(val('"hi"'))
	assert s.is_valid(val('1.5'))
	assert !s.is_valid(val('null'))
}

fn test_type_integer_semantics() {
	s := schema('{"type": "integer"}')
	assert s.is_valid(val('1'))
	assert s.is_valid(val('1.0'))
	assert s.is_valid(val('-2'))
	assert s.is_valid(val('1e1')) // 10
	assert !s.is_valid(val('1.1'))
	assert !s.is_valid(val('"1"'))
	assert !s.is_valid(val('true'))
	assert !s.is_valid(val('null'))
	assert !s.is_valid(val('{}'))
	assert !s.is_valid(val('[]'))
	assert !s.is_valid(val('"1"'))
}

fn test_type_number_semantics() {
	s := schema('{"type": "number"}')
	assert s.is_valid(val('1'))
	assert s.is_valid(val('1.0'))
	assert s.is_valid(val('1.1'))
	assert !s.is_valid(val('true')) // booleans are not numbers, even 0/1
	assert !s.is_valid(val('"1"'))
}

fn test_type_null_boolean_object_array() {
	assert schema('{"type": "null"}').is_valid(val('null'))
	assert !schema('{"type": "null"}').is_valid(val('false'))
	assert schema('{"type": "boolean"}').is_valid(val('false'))
	assert !schema('{"type": "boolean"}').is_valid(val('0'))
	assert schema('{"type": "object"}').is_valid(val('{}'))
	assert !schema('{"type": "object"}').is_valid(val('[]'))
	assert schema('{"type": "array"}').is_valid(val('[]'))
	assert !schema('{"type": "array"}').is_valid(val('{}'))
}

fn test_const_semantics() {
	assert schema('{"const": -2.0}').is_valid(val('-2'))
	assert schema('{"const": -2.0}').is_valid(val('-2.0'))
	assert !schema('{"const": -2.0}').is_valid(val('2'))
	assert schema('{"const": 1}').is_valid(val('1.0'))
	// booleans know nothing of numbers
	assert !schema('{"const": false}').is_valid(val('0'))
	assert !schema('{"const": false}').is_valid(val('0.0'))
	assert !schema('{"const": true}').is_valid(val('1'))
	assert schema('{"const": true}').is_valid(val('true'))
	// null only matches null
	assert schema('{"const": null}').is_valid(val('null'))
	assert !schema('{"const": null}').is_valid(val('0'))
}

fn test_const_deep_structures() {
	s := schema('{"const": {"foo": "bar", "baz": "bax"}}')
	assert s.is_valid(val('{"foo": "bar", "baz": "bax"}'))
	assert s.is_valid(val('{"baz": "bax", "foo": "bar"}')) // object order is irrelevant
	assert !s.is_valid(val('{"foo": "bar"}')) // missing keys do not pass
	assert !s.is_valid(val('{"foo": "bar", "baz": "bax", "x": 1}')) // extra keys too
	arr := schema('{"const": [{"foo": "bar"}]}')
	assert arr.is_valid(val('[{"foo": "bar"}]'))
	assert !arr.is_valid(val('[[2]]'))
}

fn test_const_unicode_exactness() {
	// U+03BC (greek mu) vs U+00B5 (micro sign): same glyph, different token
	assert schema('{"const": "\\u03bc"}').is_valid(val('"\\u03bc"'))
	assert !schema('{"const": "\\u03bc"}').is_valid(val('"\\u00b5"'))
	// NUL inside a string is byte-exact, not a terminator
	assert schema('{"const": "hello\\u0000there"}').is_valid(val('"hello\\u0000there"'))
	assert !schema('{"const": "hello\\u0000there"}').is_valid(val('"hellothere"'))
}

fn test_enum_semantics() {
	s := schema('{"enum": [1, 2, 3]}')
	assert s.is_valid(val('1'))
	assert !s.is_valid(val('4'))
	mixed := schema('{"enum": [6, "foo", [], true, {"foo": 12}]}')
	assert mixed.is_valid(val('[]'))
	assert mixed.is_valid(val('{"foo": 12}'))
	assert !mixed.is_valid(val('{"foo": 12, "boo": 42}'))
	assert !mixed.is_valid(val('{"foo": false}'))
	nul := schema('{"enum": [6, null]}')
	assert nul.is_valid(val('null'))
	assert nul.is_valid(val('6'))
	assert !nul.is_valid(val('"test"'))
	numeral := schema('{"enum": [false]}')
	assert numeral.is_valid(val('false'))
	assert !numeral.is_valid(val('0'))
	assert !numeral.is_valid(val('0.0'))
}

fn test_empty_enum_rejects_everything() {
	s := schema('{"enum": []}')
	assert !s.is_valid(val('"foo"'))
	assert !s.is_valid(val('42'))
	assert !s.is_valid(val('null'))
	assert !s.is_valid(val('{}'))
	assert !s.is_valid(val('[]'))
	assert !s.is_valid(val('false'))
}

fn test_numeric_bounds() {
	assert schema('{"maximum": 3.0}').is_valid(val('2.6'))
	assert schema('{"maximum": 3.0}').is_valid(val('3.0'))
	assert !schema('{"maximum": 3.0}').is_valid(val('3.5'))
	assert schema('{"maximum": 300}').is_valid(val('299.97'))
	assert schema('{"maximum": 300}').is_valid(val('300'))
	assert schema('{"maximum": 300}').is_valid(val('300.0'))
	assert !schema('{"maximum": 300}').is_valid(val('300.5'))
	// non-numbers ignore bounds
	assert schema('{"maximum": 3.0}').is_valid(val('"x"'))
	assert schema('{"minimum": -2}').is_valid(val('-1'))
	assert schema('{"minimum": -2}').is_valid(val('-2.0'))
	assert !schema('{"minimum": -2}').is_valid(val('-2.0001'))
	assert !schema('{"minimum": -2}').is_valid(val('-3'))
	assert schema('{"minimum": -2}').is_valid(val('"x"'))
	// boundaries are exact
	assert !schema('{"exclusiveMaximum": 3.0}').is_valid(val('3.0'))
	assert schema('{"exclusiveMaximum": 3.0}').is_valid(val('2.2'))
	assert !schema('{"exclusiveMinimum": 1.1}').is_valid(val('1.1'))
	assert schema('{"exclusiveMinimum": 1.1}').is_valid(val('1.2'))
}

fn test_bound_messages_carries_schema_paths() {
	errors := schema('{"maximum": 3}').validate(val('4'))
	assert errors.len == 1
	assert errors[0].schema_path == '/maximum'
	assert errors[0].instance_path == ''
	assert errors[0].message.contains('3')
}

fn test_multiple_of() {
	s := schema('{"multipleOf": 2}')
	assert s.is_valid(val('10'))
	assert !s.is_valid(val('7'))
	assert s.is_valid(val('"foo"')) // non-numbers ignore it
	s15 := schema('{"multipleOf": 1.5}')
	assert s15.is_valid(val('0'))
	assert s15.is_valid(val('4.5'))
	assert s15.is_valid(val('-4.5'))
	assert !s15.is_valid(val('35'))
	// the precision pair from the suite
	tiny := schema('{"multipleOf": 0.0001}')
	assert tiny.is_valid(val('0.0075'))
	assert !tiny.is_valid(val('0.00751'))
	// any integer is a multiple of 1e-08, despite float rounding
	e8 := schema('{"multipleOf": 1e-08}')
	assert e8.is_valid(val('12391239123'))
	// 1e308 divided by 0.123456789 overflows: never a multiple
	overflow := schema('{"type": "integer", "multipleOf": 0.123456789}')
	assert !overflow.is_valid(val('1e308'))
}

fn test_string_lengths_count_codepoints() {
	bound := schema('{"minLength": 2}')
	assert bound.is_valid(val('"foo"'))
	assert bound.is_valid(val('"fo"'))
	assert !bound.is_valid(val('"f"'))
	assert bound.is_valid(val('1')) // non-strings ignore lengths
	// one code point counts as one character, whatever its byte width
	emoji := schema('{"minLength": 1}')
	assert emoji.is_valid(val('"🇻"'))
	short := schema('{"minLength": 2}')
	assert !short.is_valid(val('"🇻"'))
	maxlen := schema('{"maxLength": 2}')
	assert maxlen.is_valid(val('"🇻🇻"'))
	assert !maxlen.is_valid(val('"foo"'))
	dec := schema('{"minLength": 2.0}')
	assert dec.is_valid(val('"foo"'))
	assert !dec.is_valid(val('"f"'))
}

fn test_properties_and_required() {
	s := schema('{"type": "object", "properties": {"name": {"type": "string"}, "n": {"type": "integer"}}, "required": ["name"]}')
	assert s.is_valid(val('{"name": "gil", "n": 42}'))
	// an empty object misses the required "name" — but n was never there
	assert !s.is_valid(val('{}'))
	assert !s.is_valid(val('{"name": 5}'))
}

fn test_required_reports_missing_keys() {
	s := schema('{"required": ["a", "b"]}')
	// both misses are collected in one pass, in required order
	errors := s.validate(val('{"b": 1}'))
	assert errors.len == 1
	assert errors[0].instance_path == ''
	assert errors[0].schema_path == '/required'
	assert err_texts(errors) == 'required property "a" is missing'
}

fn test_property_error_paths() {
	s := schema('{"properties": {"user": {"properties": {"name": {"type": "string"}}}}}')
	errors := s.validate(val('{"user": {"name": 5}}'))
	assert errors.len == 1
	assert errors[0].instance_path == '/user/name'
	assert errors[0].schema_path == '/properties/user/properties/name/type'
}

fn test_pointer_escaping_in_paths() {
	s := schema('{"properties": {"a~b/c": {"minimum": 10}}}')
	errors := s.validate(val('{"a~b/c": 1}'))
	assert errors.len == 1
	assert errors[0].instance_path == '/a~0b~1c'
	assert errors[0].schema_path == '/properties/a~0b~1c/minimum'
}

fn test_property_names() {
	s := schema('{"propertyNames": {"pattern": "^[a-z]+$"}}')
	assert s.is_valid(val('{}'))
	assert !s.is_valid(val('{"VALID": 1}'))
	errors := s.validate(val('{"VALID": 1}'))
	assert errors.len == 1
	assert errors[0].instance_path == '/VALID'
	assert errors[0].schema_path == '/propertyNames/pattern'
}

fn test_property_count_bounds() {
	lo := schema('{"minProperties": 2}')
	assert lo.is_valid(val('{"a": 1, "b": 2}'))
	assert !lo.is_valid(val('{"a": 1}'))
	hi := schema('{"maxProperties": 1}')
	assert !hi.is_valid(val('{"a": 1, "b": 2}'))
	// counts only apply to objects; a string instance is unaffected
	assert schema('{"minProperties": 2}').is_valid(val('"two"'))
}

fn test_items() {
	s := schema('{"items": {"type": "integer", "minimum": 0}}')
	assert s.is_valid(val('[1, 2, 3]'))
	assert !s.is_valid(val('[1, -2, 3]'))
	errors := s.validate(val('[1, -2, 3]'))
	assert errors.len == 1
	assert errors[0].instance_path == '/1'
	assert errors[0].schema_path == '/items/minimum'
}

fn test_item_count_bounds() {
	lo := schema('{"minItems": 2}')
	assert lo.is_valid(val('[1, 2]'))
	assert !lo.is_valid(val('[1]'))
	hi := schema('{"maxItems": 2}')
	assert hi.is_valid(val('[1, 2]'))
	assert !hi.is_valid(val('[1, 2, 3]'))
}

fn test_unique_items() {
	s := schema('{"uniqueItems": true}')
	assert s.is_valid(val('[1, 2, 3]'))
	// deep, kind-first equality: -2 == -2.0, false != 0
	assert !s.is_valid(val('[1, -2, -2.0]'))
	assert s.is_valid(val('[false, 0]'))
	assert !s.is_valid(val('[{"a": 1, "b": 2}, {"b": 2, "a": 1}]'))
	assert s.is_valid(val('"abc"'))
}

fn test_contains() {
	c := schema('{"contains": {"const": 2}}')
	assert c.is_valid(val('[1, 2, 3]'))
	assert !c.is_valid(val('[1, 3]'))
	assert !c.is_valid(val('[]'))
	// contains: false rejects everything; true accepts any array
	assert !schema('{"contains": false}').is_valid(val('[1]'))
	assert schema('{"contains": true}').is_valid(val('[1]'))
}

fn test_contains_bounds() {
	mc := schema('{"contains": {"const": 2}, "maxContains": 1}')
	assert mc.is_valid(val('[2, 3]'))
	assert !mc.is_valid(val('[2, 2]'))
	// minContains: 0 makes zero matches valid, even on the empty array
	m0 := schema('{"contains": {"const": 2}, "minContains": 0}')
	assert m0.is_valid(val('[]'))
	assert m0.is_valid(val('[1, 3]'))
	// a raised minimum is reported at its own path
	m3 := schema('{"contains": {"const": 2}, "minContains": 3}')
	errors := m3.validate(val('[2, 3]'))
	assert errors.len == 1
	assert errors[0].schema_path == '/minContains'
}

fn test_parse_rejects_malformed_structure() {
	assert rejects('{"required": "a"}')
	assert rejects('{"required": [1]}')
	assert rejects('{"properties": []}')
	assert rejects('{"uniqueItems": "yes"}')
	assert rejects('{"items": 5}')
	assert rejects('{"minProperties": -1}')
	assert rejects('{"maxItems": 2.5}')
	assert rejects('{"contains": 42}')
	// bad subschema keywords are loud, wherever they sit
	assert rejects('{"properties": {"a": {"multipleOf": 0}}}')
	// unknown keywords inside subschemas stay annotations
	assert !rejects('{"properties": {"a": {"description": "x"}}}')
}

fn test_pattern_semantics() {
	anchored := schema('{"pattern": "^a*$"}')
	assert anchored.is_valid(val('"aaa"'))
	assert !anchored.is_valid(val('"abc"'))
	// the draft uses substring search: an unanchored pattern matches anywhere
	unanchored := schema('{"pattern": "a+"}')
	assert unanchored.is_valid(val('"xxaayy"'))
	// non-string values always match the pattern
	ignored := schema('{"pattern": "^a*$"}')
	assert ignored.is_valid(val('true'))
	assert ignored.is_valid(val('123'))
	assert ignored.is_valid(val('1.0'))
	assert ignored.is_valid(val('{}'))
	assert ignored.is_valid(val('[]'))
	assert ignored.is_valid(val('null'))
	pi := schema('{"pattern": "^π$"}')
	assert pi.is_valid(val('"π"'))
	assert !pi.is_valid(val('"b"'))
}

fn test_validate_json_reports_malformed_json() {
	s := schema('{"type": "string"}')
	errors := s.validate_json('"ok"') or { panic('should parse') }
	assert errors.len == 0
	bad := s.validate_json('{') or { return }
	panic('malformed JSON must error, got ${bad.len} violations')
}

fn test_errors_collect_not_short_circuit() {
	// 1.5 fails type integer AND the not-a-multiple rule
	errors := schema('{"type": "integer", "multipleOf": 2}').validate(val('1.5'))
	assert errors.len == 2, err_texts(errors)
	assert errors[0].schema_path == '/type'
	assert errors[1].schema_path == '/multipleOf'
}
