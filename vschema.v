// vschema is a JSON Schema validator for V, targeting
// https://json-schema.org/draft/2020-12.
//
// It parses schemas over `json2.Any` values (the plain JSON trees produced by
// `json2.parse`), validates instances keyword by keyword, and reports
// violations as structured rows: where the instance failed
// (`VError.instance_path`, a JSON Pointer), which part of the schema produced
// the rule (`VError.schema_path`) and why (`VError.message`).
//
// The first release covers the core keywords: boolean schemas, `type`,
// `const`, `enum`, the numeric keywords (`maximum`, `minimum`,
// `exclusiveMaximum`, `exclusiveMinimum`, `multipleOf`), the string keywords
// (`maxLength`, `minLength`, `pattern`), object and array structure
// (`properties`, `required`, `propertyNames`, `items`, `contains`, the count
// bounds), composition (`allOf`, `anyOf`, `oneOf`, `not`), and `$ref`/`$defs`
// fragment references — plus comptime derivation from V structs
// (`schema_of`/`schema_json`). Keywords beyond this set are treated as
// annotations and ignored, per the draft; the conformance report names the
// gap explicitly.
//
// The official conformance corpus (json-schema-org/JSON-Schema-Test-Suite)
// is exercised by conformance_test.v when a dev-only `testsuite/` clone
// exists under the repository root.
module vschema
