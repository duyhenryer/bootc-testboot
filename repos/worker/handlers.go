package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// Global service managers (set in main.go)
var (
	appCfg    *Config
	mongoMgr  *MongoDBManager
	amqpMgr   *RabbitMQManager
	valkeyMgr *ValkeyManager
)

func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"service": "worker",
		"version": version,
		"status":  "running",
		"mode":    "seed",
	})
	slog.Debug("GET / responded")
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	allOk, status := HealthCheck(ctx)

	statusCode := http.StatusOK
	if !allOk {
		statusCode = http.StatusServiceUnavailable
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)

	response := map[string]interface{}{
		"status":      "ok",
		"mongodb":     status["mongodb"],
		"rabbitmq":    status["rabbitmq"],
		"valkey":      status["valkey"],
		"timestamp":   time.Now().UTC().Format(time.RFC3339),
	}
	if !allOk {
		response["status"] = "degraded"
	}

	json.NewEncoder(w).Encode(response)
	slog.Debug("GET /health responded", "status", response["status"])
}

func handleStatusMongoDB(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	dbName := "testboot_db"
	if appCfg != nil && appCfg.MongoDBName != "" {
		dbName = appCfg.MongoDBName
	}

	var status string
	collCounts := map[string]int64{}
	var total int64

	if mongoMgr != nil && mongoMgr.Connected() {
		status = "connected"
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for _, name := range DefaultSeedCollections {
			c, err := mongoMgr.Count(ctx, name)
			if err != nil {
				status = "error"
				slog.Warn("mongodb count failed", "collection", name, "err", err)
				break
			}
			collCounts[name] = c
			total += c
		}
	} else {
		status = "disconnected"
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":          status,
		"database":        dbName,
		"collections":     collCounts,
		"document_count":  total,
	})
	slog.Debug("GET /status/mongodb responded", "status", status, "count", total)
}

func handleStatusRabbitMQ(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var status string
	if amqpMgr != nil && amqpMgr.conn != nil && !amqpMgr.conn.IsClosed() {
		status = "connected"
	} else {
		status = "disconnected"
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":          status,
		"queue":           "worker_queue",
		"consumer_count":  0,
		"message_count":   0,
	})
	slog.Debug("GET /status/rabbitmq responded", "status", status)
}

func handleStatusValkey(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var status string
	var ping string
	if valkeyMgr != nil && valkeyMgr.client != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := valkeyMgr.Ping(ctx); err == nil {
			status = "connected"
			ping = "PONG"
		} else {
			status = "error"
			ping = err.Error()
		}
	} else {
		status = "disconnected"
		ping = "N/A"
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": status,
		"database": 0,
		"ping":   ping,
	})
	slog.Debug("GET /status/valkey responded", "status", status)
}

func handleSeed(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	body, err := io.ReadAll(r.Body)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "failed to read request body",
		})
		slog.Warn("POST /seed failed to read body", "err", err)
		return
	}

	var req seedRequest
	if err := json.Unmarshal(body, &req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "invalid json",
		})
		slog.Warn("POST /seed invalid json", "err", err)
		return
	}

	timeoutSec := 1800
	batchSize := 1000
	if appCfg != nil {
		timeoutSec = appCfg.SeedHTTPTimeoutSec
		batchSize = appCfg.SeedBatchSize
	}
	if timeoutSec < 30 {
		timeoutSec = 30
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()

	startTime := time.Now()
	var errMsg string

	if mongoMgr == nil || !mongoMgr.Connected() {
		errMsg = "mongodb not connected"
		slog.Warn("seeding skipped - mongodb not connected")
		writeSeedError(w, errMsg)
		return
	}

	mbMode := req.TargetSizeMB > 0 || len(req.Collections) > 0 || req.Parallel != nil || req.BatchSize > 0
	legacyOnly := !mbMode
	if legacyOnly {
		if req.Count == 0 {
			req.Count = 100
		}
		inserted, err := SeedCollectionUsers(ctx, mongoMgr, req.Count)
		if err != nil {
			errMsg = err.Error()
			slog.Error("seeding failed", "err", err)
			writeSeedError(w, errMsg)
			return
		}
		slog.Info("seeding completed", "mode", "legacy_users", "count", inserted, "duration_ms", time.Since(startTime).Milliseconds())
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"inserted":    inserted,
			"collection":  "users",
			"status":      "success",
			"duration_ms": time.Since(startTime).Milliseconds(),
		})
		return
	}

	targetMB := req.TargetSizeMB
	if targetMB == 0 && appCfg != nil {
		targetMB = appCfg.SeedTargetSizeMB
	}
	if req.BatchSize > 0 {
		batchSize = req.BatchSize
	}
	parallel := true
	if req.Parallel != nil {
		parallel = *req.Parallel
	}

	res, err := SeedParallel(ctx, mongoMgr, SeedParams{
		TargetSizeMB: targetMB,
		Collections:  req.Collections,
		BatchSize:    batchSize,
		Parallel:     parallel,
	})
	if err != nil {
		errMsg = err.Error()
		slog.Error("seeding failed", "err", err)
		writeSeedError(w, errMsg)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":         "success",
		"inserted":       res.TotalInserted,
		"by_collection":  res.ByCollection,
		"duration_ms":    time.Since(startTime).Milliseconds(),
		"target_size_mb": clampSeedTargetMB(targetMB),
	})
}

func writeSeedError(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusInternalServerError)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "error",
		"error":  msg,
	})
}

type seedRequest struct {
	Count          int      `json:"count"`
	ClearFirst     bool     `json:"clear_first"`
	TargetSizeMB   int      `json:"target_size_mb"`
	Collections    []string `json:"collections"`
	Parallel       *bool    `json:"parallel"`
	BatchSize      int      `json:"batch_size"`
}
