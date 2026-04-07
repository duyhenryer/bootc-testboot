package main

import (
	"context"
	"io"
	"log/slog"
	"net"
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

	// Load configuration
	cfg, err := loadConfig()
	if err != nil {
		slog.Error("config load failed", "err", err)
		os.Exit(1)
	}

	mongoMgr := &MongoDBManager{}
	amqpMgr := &RabbitMQManager{}
	valkeyMgr := &ValkeyManager{}
	setServiceManagers(cfg, mongoMgr, amqpMgr, valkeyMgr)

	// HTTP must listen before backend connections so systemd ExecStartPost and
	// probes see an open port; /health may stay 503 until deps are up.
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/status/mongodb", handleStatusMongoDB)
	mux.HandleFunc("/status/rabbitmq", handleStatusRabbitMQ)
	mux.HandleFunc("/status/valkey", handleStatusValkey)
	mux.HandleFunc("POST /seed", handleSeed)

	writeTimeout := time.Duration(cfg.SeedHTTPTimeoutSec) * time.Second
	if writeTimeout < 30*time.Second {
		writeTimeout = 30 * time.Second
	}
	writeTimeout += 30 * time.Second

	srv := &http.Server{
		Handler:      mux,
		ErrorLog:     slog.NewLogLogger(slog.Default().Handler(), slog.LevelError),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: writeTimeout,
		IdleTimeout:  60 * time.Second,
	}

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		slog.Error("listen failed", "addr", cfg.ListenAddr, "err", err)
		os.Exit(1)
	}

	go func() {
		slog.Info("worker listening", "version", version, "addr", ln.Addr().String())
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			slog.Error("serve failed", "err", err)
			os.Exit(1)
		}
	}()

	ctx := context.Background()
	mongoURI := cfg.buildMongoDBURI()
	if err := mongoMgr.Connect(ctx, mongoURI, cfg.MongoDBName, cfg.MongoDBMaxPoolSize); err != nil {
		slog.Error("failed to connect to mongodb", "err", err)
	} else {
		for _, coll := range DefaultSeedCollections {
			if err := mongoMgr.EnsureCollection(ctx, coll); err != nil {
				slog.Error("failed to ensure collection", "collection", coll, "err", err)
			}
		}
	}

	rabbitURI := cfg.buildRabbitMQURI()
	if err := amqpMgr.Connect(ctx, rabbitURI, cfg.RabbitMQQueue); err != nil {
		slog.Error("failed to connect to rabbitmq", "err", err)
	}

	if err := valkeyMgr.Connect(ctx, cfg.ValkeyAddr, cfg.ValkeyDB); err != nil {
		slog.Error("failed to connect to valkey", "err", err)
	}

	// Wait for shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	slog.Info("shutting down")

	// Graceful shutdown with 10-second timeout
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Close managers
	if err := mongoMgr.Close(ctx); err != nil {
		slog.Warn("mongodb close failed", "err", err)
	}
	if err := amqpMgr.Close(); err != nil {
		slog.Warn("rabbitmq close failed", "err", err)
	}
	if err := valkeyMgr.Close(); err != nil {
		slog.Warn("valkey close failed", "err", err)
	}

	// Shutdown server
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

func parseLogLevel(levelStr string) slog.Level {
	levelStr = strings.ToLower(strings.TrimSpace(levelStr))
	switch levelStr {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func setServiceManagers(cfg *Config, mongo *MongoDBManager, amqp *RabbitMQManager, valkey *ValkeyManager) {
	appCfg = cfg
	mongoMgr = mongo
	amqpMgr = amqp
	valkeyMgr = valkey
}
