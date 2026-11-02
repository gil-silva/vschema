// vschema CLI — validate a JSON document against a JSON Schema, or lint a schema on its own.
// Build: v .   (→ bin/vschema)
// Run:   vschema <schema.json> [<document.json>]
// With a document: prints `valid`, or one structured violation line per error.
// Without one: parses the schema and reports what is wrong with it (lint mode).
module main

import os
import vschema

// parse_or_exit reads and parses the schema file, exiting with its message on failure.
fn parse_or_exit(schema_path string) vschema.Schema {
	raw_schema := os.read_file(schema_path) or {
		eprintln('vschema: schema: ${err.msg()}')
		exit(1)
	}
	return vschema.parse_schema_json(raw_schema) or {
		eprintln('vschema: schema: ${err.msg()}')
		exit(1)
	}
}

fn run(schema_path string, doc_path string) {
	s := parse_or_exit(schema_path)
	raw_doc := os.read_file(doc_path) or {
		eprintln('vschema: document: ${err.msg()}')
		exit(1)
	}
	errors := s.validate_json(raw_doc) or {
		eprintln('vschema: document: ${err.msg()}')
		exit(1)
	}
	if errors.len == 0 {
		println('valid')
		return
	}
	for e in errors {
		println('error at "${e.instance_path}" (${e.schema_path}): ${e.message}')
	}
	exit(1)
}

fn main() {
	if os.args.len == 2 {
		// lint mode: no document, the schema itself is under test
		_ = parse_or_exit(os.args[1])
		println('schema ok')
	} else if os.args.len == 3 {
		run(os.args[1], os.args[2])
	} else {
		println('usage: vschema <schema.json> [<document.json>]')
		exit(1)
	}
}
