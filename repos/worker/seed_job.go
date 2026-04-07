package main

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/errgroup"
)

// SeedParams configures a multi-collection bulk seed.
type SeedParams struct {
	TargetSizeMB int
	Collections  []string
	BatchSize    int
	Parallel     bool
}

// SeedResult summarizes inserted documents.
type SeedResult struct {
	TotalInserted int
	ByCollection  map[string]int
	Duration      time.Duration
}

var allowedSeedCollections = map[string]struct{}{
	"users":   {},
	"orders":  {},
	"events":  {},
	"metrics": {},
}

func normalizeCollections(names []string) ([]string, error) {
	if len(names) == 0 {
		out := make([]string, len(DefaultSeedCollections))
		copy(out, DefaultSeedCollections)
		return out, nil
	}
	var out []string
	for _, n := range names {
		n = strings.TrimSpace(strings.ToLower(n))
		if n == "" {
			continue
		}
		if _, ok := allowedSeedCollections[n]; !ok {
			return nil, fmt.Errorf("unknown collection: %q", n)
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no valid collections")
	}
	return out, nil
}

func docsPerCollectionForTargetMB(targetMB int, numCollections int) int {
	if targetMB < 1 {
		targetMB = 400
	}
	if numCollections < 1 {
		numCollections = len(DefaultSeedCollections)
	}
	total := int64(targetMB) * 1024 * 1024
	perColl := total / int64(numCollections)
	n := int(perColl / approxAvgDocBytes)
	if n < 1 {
		n = 1
	}
	return n
}

func clampSeedTargetMB(mb int) int {
	if mb < 1 {
		mb = 400
	}
	if mb < 300 {
		return 300
	}
	if mb > 500 {
		return 500
	}
	return mb
}

// SeedParallel inserts mock documents into the given collections using unordered batches.
func SeedParallel(ctx context.Context, m *MongoDBManager, p SeedParams) (*SeedResult, error) {
	start := time.Now()
	colls, err := normalizeCollections(p.Collections)
	if err != nil {
		return nil, err
	}
	batchSize := p.BatchSize
	if batchSize < 1 {
		batchSize = 1000
	}
	reqMB := p.TargetSizeMB
	targetMB := clampSeedTargetMB(p.TargetSizeMB)
	if reqMB > 0 && targetMB != reqMB {
		slog.Info("seed target_size_mb clamped", "requested", reqMB, "used", targetMB)
	}
	numPerColl := docsPerCollectionForTargetMB(targetMB, len(colls))

	result := &SeedResult{
		ByCollection: make(map[string]int),
	}

	if p.Parallel {
		var mu sync.Mutex
		g, gctx := errgroup.WithContext(ctx)
		for _, name := range colls {
			name := name
			g.Go(func() error {
				n, err := seedOneCollection(gctx, m, name, numPerColl, batchSize)
				if err != nil {
					return err
				}
				mu.Lock()
				result.ByCollection[name] = n
				mu.Unlock()
				slog.Info("mongodb_seed_collection_done", "collection", name, "inserted", n)
				return nil
			})
		}
		if err := g.Wait(); err != nil {
			return nil, err
		}
	} else {
		for _, name := range colls {
			n, err := seedOneCollection(ctx, m, name, numPerColl, batchSize)
			if err != nil {
				return nil, err
			}
			result.ByCollection[name] = n
			slog.Info("mongodb_seed_collection_done", "collection", name, "inserted", n)
		}
	}

	var total int
	for _, n := range result.ByCollection {
		total += n
	}
	result.TotalInserted = total
	result.Duration = time.Since(start)
	slog.Info("mongodb_seed_job_done", "total_inserted", total, "duration_ms", result.Duration.Milliseconds(), "collections", colls)
	return result, nil
}

func seedOneCollection(ctx context.Context, m *MongoDBManager, coll string, total int, batchSize int) (int, error) {
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	var inserted int
	batchIdx := 0
	for offset := 0; offset < total; offset += batchSize {
		n := batchSize
		if offset+n > total {
			n = total - offset
		}
		docs := make([]interface{}, n)
		for i := 0; i < n; i++ {
			switch coll {
			case "users":
				docs[i] = GenerateMockUser(rng)
			case "orders":
				docs[i] = GenerateMockOrder(rng)
			case "events":
				docs[i] = GenerateMockEvent(rng)
			case "metrics":
				docs[i] = GenerateMockMetric(rng)
			default:
				return inserted, fmt.Errorf("unsupported collection %q", coll)
			}
		}
		ins, err := m.InsertMany(ctx, coll, docs)
		if err != nil {
			return inserted, err
		}
		inserted += ins
		slog.Info("mongodb_seed_batch",
			"collection", coll,
			"batch_index", batchIdx,
			"batch_docs", n,
			"inserted", ins,
		)
		batchIdx++
	}
	return inserted, nil
}
