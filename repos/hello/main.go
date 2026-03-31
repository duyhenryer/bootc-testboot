package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

func main() {
	logFile, err := setupLogger()
	if err != nil {
		slog.Error("logger setup failed", "err", err)
		os.Exit(1)
	}
	if logFile != nil {
		defer logFile.Close()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/health", handleHealth)

	addr := ":8000"
	if v := os.Getenv("LISTEN_ADDR"); v != "" {
		addr = v
	}

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ErrorLog:     slog.NewLogLogger(slog.Default().Handler(), slog.LevelError),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		slog.Info("hello listening", "version", version, "addr", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	slog.Info("shutting down")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("shutdown failed", "err", err)
		os.Exit(1)
	}
	slog.Info("stopped")
}

func setupLogger() (*os.File, error) {
	level := parseLogLevel(os.Getenv("LOG_LEVEL"))

	format := strings.ToLower(strings.TrimSpace(os.Getenv("LOG_FORMAT")))
	if format != "json" && format != "text" {
		format = "text"
	}

	logPath := strings.TrimSpace(os.Getenv("LOG_FILE"))
	var file *os.File
	var err error
	if logPath != "" {
		file, err = os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
		if err != nil {
			return nil, err
		}
	}

	out := io.Writer(os.Stdout)
	if file != nil {
		out = io.MultiWriter(os.Stdout, file)
	}

	opts := &slog.HandlerOptions{Level: level}
	var h slog.Handler
	if format == "json" {
		h = slog.NewJSONHandler(out, opts)
	} else {
		h = slog.NewTextHandler(out, opts)
	}
	slog.SetDefault(slog.New(h))
	return file, nil
}

func parseLogLevel(s string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	case "info", "":
		return slog.LevelInfo
	default:
		return slog.LevelInfo
	}
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	resp := map[string]string{
		"message":  "hello bootc",
		"hostname": hostname,
		"version":  version,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}
