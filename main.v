// vschema CLI — validate a JSON document against a JSON Schema.
// Build: v .   (→ bin/vschema)
// Run:   vschema <schema.json> <document.json>
// Prints `valid`, or one structured violation line per error.
module main

import os
import vschema

fn run(schema_path string, doc_path string) {
	raw_schema := os.read_file(schema_path) or {
		eprintln('vschema: schema: ${err.msg()}')
		exit(1)
	}
	s := vschema.parse_schema_json(raw_schema) or {
		eprintln('vschema: schema: ${err.msg()}')
		exit(1)
	}
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
	if os.args.len != 3 {
		println('usage: vschema <schema.json> <document.json>')
		exit(1)
	}
	run(os.args[1], os.args[2])
}
