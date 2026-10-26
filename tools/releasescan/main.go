// Command releasescan is the shipping-build gate: it fails when an exported pack still contains the
// Glitchscout SDK. Game-side integration names (groups, metadata, get_node_or_null("/root/Glitchscout"))
// are expected and don't count; the SDK's own files, class and protocol strings do.
//
//	go run . build/release.pck              # exit 1 if the SDK is in it
//	go run . -expect-sdk build/qa.pck       # exit 1 if it isn't (proves the scan can see it)
package main

import (
	"archive/zip"
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
)

// markers are strings only the SDK itself carries.
var markers = []string{"res://addons/glitchscout/", "GlitchscoutSDK", "glitchscout/1", "--glitchscout-endpoint"}

// autoload is the project setting a QA build needs for the SDK to run (the export plugin strips it from
// builds that leave the addon out).
const autoload = "autoload/Glitchscout"

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
		data, err := contents(path)
		if err != nil {
			return err
		}
		hits := found(data)
		switch {
		case *expectSDK && len(hits) == 0:
			return fmt.Errorf("%s: no SDK found, but this build should contain it", path)
		case *expectSDK && !bytes.Contains(data, []byte(autoload)):
			return fmt.Errorf("%s: the SDK files are there but its %s setting isn't, so it would never start", path, autoload)
		case !*expectSDK && len(hits) > 0:
			return fmt.Errorf("%s: the Glitchscout SDK is in a shipping build: %q", path, hits)
		}
		fmt.Printf("releasescan: %s: %d SDK markers\n", path, len(hits))
	}
	return nil
}

// scan returns the SDK markers found in a pack.
func scan(path string) ([]string, error) {
	data, err := contents(path)
	if err != nil {
		return nil, err
	}
	return found(data), nil
}

// contents returns what a pack holds: an uncompressed .pck or executable as it is, or a .zip export's
// entries inflated one by one, each preceded by its res:// path.
func contents(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !bytes.HasPrefix(data, []byte("PK\x03\x04")) {
		return data, nil
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	all := []byte{}
	for _, f := range zr.File {
		all = append(all, "\nres://"+f.Name+"\n"...)
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("%s: %s: %w", path, f.Name, err)
		}
		b, err := io.ReadAll(rc)
		_ = rc.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %s: %w", path, f.Name, err)
		}
		all = append(all, b...)
	}
	return all, nil
}

func found(data []byte) []string {
	var hits []string
	for _, m := range markers {
		if bytes.Contains(data, []byte(m)) {
			hits = append(hits, m)
		}
	}
	return hits
}
