// Command schemacheck validates JSON protocol messages captured from the SDK's tests against the
// glitchscout/1 schemas in github.com/glitchscout/protocol.
//
//	go run . [-min n] <dir>   # every *.json file in dir must be a valid message; -min requires n of them
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/santhosh-tekuri/jsonschema/v6"

	spec "github.com/glitchscout/protocol"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "schemacheck:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("schemacheck", flag.ContinueOnError)
	minMessages := fs.Int("min", 0, "fail unless at least this many messages were captured")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: schemacheck [-min n] <dir>")
	}
	n, bad, err := check(fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Printf("schemacheck: %d messages, %d invalid\n", n, bad)
	switch {
	case bad > 0:
		return fmt.Errorf("%d invalid messages", bad)
	case n < *minMessages:
		return fmt.Errorf("only %d messages captured, want at least %d: is the test mock still saving them?", n, *minMessages)
	}
	return nil
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
