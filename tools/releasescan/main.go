// Command releasescan is the shipping-build gate: it fails when an exported pack still contains the
// Glitchscout SDK. Game-side integration names (groups, metadata, get_node_or_null("/root/Glitchscout"))
// are expected and don't count; the SDK's own files, class and protocol strings do.
//
//	go run . build/release.pck              # exit 1 if the SDK is in it
//	go run . -expect-sdk build/qa.pck       # exit 1 if it isn't (proves the scan can see it)
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"os"
)

// markers are strings only the SDK itself carries.
var markers = []string{"res://addons/glitchscout/", "GlitchscoutSDK", "glitchscout/1", "--glitchscout-endpoint"}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "releasescan:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("releasescan", flag.ContinueOnError)
	expectSDK := fs.Bool("expect-sdk", false, "fail unless the SDK is found (a QA build)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() == 0 {
		return errors.New("usage: releasescan [-expect-sdk] <pack>...")
	}
	for _, path := range fs.Args() {
		hits, err := scan(path)
		if err != nil {
			return err
		}
		switch {
		case *expectSDK && len(hits) == 0:
			return fmt.Errorf("%s: no SDK found, but this build should contain it", path)
		case !*expectSDK && len(hits) > 0:
			return fmt.Errorf("%s: the Glitchscout SDK is in a shipping build: %q", path, hits)
		}
		fmt.Printf("releasescan: %s: %d SDK markers\n", path, len(hits))
	}
	return nil
}

// scan returns the SDK markers found in a file.
func scan(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var hits []string
	for _, m := range markers {
		if bytes.Contains(data, []byte(m)) {
			hits = append(hits, m)
		}
	}
	return hits, nil
}
