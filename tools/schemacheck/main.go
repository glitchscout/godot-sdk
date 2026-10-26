// Command schemacheck validates JSON protocol messages captured from the SDK's tests against the
// glitchscout/1 schemas in github.com/glitchscout/protocol.
//
//	go run . <dir>   # every *.json file in dir must be a valid message
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"github.com/santhosh-tekuri/jsonschema/v6"

	spec "github.com/glitchscout/protocol"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: schemacheck <dir>")
		os.Exit(2)
	}
	n, bad, err := check(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "schemacheck:", err)
		os.Exit(2)
	}
	fmt.Printf("schemacheck: %d messages, %d invalid\n", n, bad)
	if bad > 0 {
		os.Exit(1)
	}
}

func check(dir string) (n, bad int, err error) {
	c, err := spec.Compiler(spec.FS)
	if err != nil {
		return 0, 0, err
	}
	sch, err := c.Compile(spec.SchemaURL("schemas/message.schema.json"))
	if err != nil {
		return 0, 0, err
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return 0, 0, err
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return n, bad, err
		}
		n++
		doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
		if err == nil {
			err = sch.Validate(doc)
		}
		if err != nil {
			bad++
			fmt.Fprintf(os.Stderr, "%s: %s\n%v\n", filepath.Base(f), data, err)
		}
	}
	return n, bad, nil
}
