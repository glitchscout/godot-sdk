package main

import (
	"strings"
	"testing"
	"time"
)

func ms(v float64) time.Duration { return time.Duration(v * float64(time.Millisecond)) }

func TestSummarize(t *testing.T) {
	var samples []time.Duration
	for i := 1; i <= 100; i++ { // 1..100 ms, shuffled order doesn't matter
		samples = append(samples, ms(float64(101-i)))
	}
	s := summarize(samples)
	if s.N != 100 || s.P50MS != 50 || s.P95MS != 95 || s.P99MS != 99 || s.MaxMS != 100 {
		t.Fatalf("summarize = %+v", s)
	}
	if samples[0] != ms(100) {
		t.Fatal("summarize reordered its input")
	}
}

func TestGate(t *testing.T) {
	if err := gate(Summary{N: 1000, P50MS: 1.2, P95MS: 9}, 5); err != nil {
		t.Fatalf("median 1.2 ms against 5 ms: %v", err)
	}
	if err := gate(Summary{N: 1000, P50MS: 5.01}, 5); err == nil {
		t.Fatal("a median over the limit passed")
	}
	if err := gate(Summary{N: 0}, 5); err == nil {
		t.Fatal("no samples passed")
	}
}

func TestNewUUIDIsVersion4(t *testing.T) {
	for range 100 {
		u := newUUID()
		if len(u) != 36 || u[14] != '4' || !strings.ContainsRune("89ab", rune(u[19])) {
			t.Fatalf("newUUID() = %q, want an RFC 4122 v4 UUID", u)
		}
	}
}
