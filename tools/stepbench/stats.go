package main

import (
	"errors"
	"fmt"
	"math"
	"slices"
	"time"
)

// Summary describes the measured STEP round trips.
type Summary struct {
	N     int     `json:"n"`
	P50MS float64 `json:"p50_ms"`
	P95MS float64 `json:"p95_ms"`
	P99MS float64 `json:"p99_ms"`
	MaxMS float64 `json:"max_ms"`
}

// summarize computes nearest-rank percentiles without reordering samples.
func summarize(samples []time.Duration) Summary {
	if len(samples) == 0 {
		return Summary{}
	}
	sorted := slices.Clone(samples)
	slices.Sort(sorted)
	pct := func(p float64) float64 {
		i := int(math.Ceil(p/100*float64(len(sorted)))) - 1
		return toMS(sorted[max(i, 0)])
	}
	return Summary{N: len(sorted), P50MS: pct(50), P95MS: pct(95), P99MS: pct(99), MaxMS: toMS(sorted[len(sorted)-1])}
}

func toMS(d time.Duration) float64 {
	return math.Round(float64(d)/float64(time.Millisecond)*1000) / 1000
}

// gate fails when the median round trip is over maxP50MS. The median, not a tail percentile, because
// shared CI runners have scheduling hiccups that say nothing about the SDK.
func gate(s Summary, maxP50MS float64) error {
	switch {
	case s.N == 0:
		return errors.New("no steps measured")
	case s.P50MS > maxP50MS:
		return fmt.Errorf("median step overhead %.3f ms is over the %.1f ms limit", s.P50MS, maxP50MS)
	}
	return nil
}
