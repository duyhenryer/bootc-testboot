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

	var status string
	var count int64

	if mongoMgr != nil && mongoMgr.collection != nil {
		status = "connected"
		var err error
		count, err = mongoMgr.Count(context.Background())
		if err != nil {
			status = "error"
			slog.Warn("mongodb count failed", "err", err)
		}
	} else {
		status = "disconnected"
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":         status,
		"database":       "testboot_db",
		"collection":     "users",
		"document_count": count,
	})
	slog.Debug("GET /status/mongodb responded", "status", status, "count", count)
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

	// Parse request body
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

	// Default count if not provided
	if req.Count == 0 {
		req.Count = 100
	}

	// Seed data
	startTime := time.Now()
	var inserted int
	var errMsg string

	if mongoMgr != nil && mongoMgr.collection != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		var err error
		inserted, err = SeedCollection(ctx, mongoMgr, "users", req.Count)
		if err != nil {
			errMsg = err.Error()
			slog.Error("seeding failed", "err", err)
		} else {
			slog.Info("seeding completed", "count", inserted, "duration_ms", time.Since(startTime).Milliseconds())
		}
	} else {
		errMsg = "mongodb not connected"
		slog.Warn("seeding skipped - mongodb not connected")
	}

	// Return response
	w.Header().Set("Content-Type", "application/json")
	if errMsg != "" {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status":       "error",
			"error":        errMsg,
			"collection":   "users",
		})
	} else {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"inserted":    inserted,
			"collection":  "users",
			"status":      "success",
			"duration_ms": time.Since(startTime).Milliseconds(),
		})
	}
}

type seedRequest struct {
	Count      int  `json:"count"`
	ClearFirst bool `json:"clear_first"`
}

func getHealthStatus() map[string]interface{} {
	return map[string]interface{}{
		"status":      "ok",
		"mongodb":     "checking",
		"rabbitmq":    "checking",
		"valkey":      "checking",
		"timestamp":   time.Now().UTC().Format(time.RFC3339),
	}
}
