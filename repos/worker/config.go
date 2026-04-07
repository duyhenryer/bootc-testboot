package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	ListenAddr         string
	LogLevel           string
	LogFormat          string
	LogFile            string
	WorkerMode         string
	MockDataCount      int
	MongoDBURI         string
	MongoDBName        string
	MongoDBMaxPoolSize uint64
	RabbitMQURI        string
	RabbitMQQueue      string
	ValkeyAddr         string
	ValkeyDB           int
	SeedHTTPTimeoutSec int
	SeedBatchSize      int
	SeedTargetSizeMB   int
}

func loadConfig() (*Config, error) {
	cfg := &Config{
		ListenAddr:         getEnv("LISTEN_ADDR", ":8001"),
		LogLevel:           getEnv("LOG_LEVEL", "info"),
		LogFormat:          getEnv("LOG_FORMAT", "text"),
		LogFile:            getEnv("LOG_FILE", ""),
		WorkerMode:         getEnv("WORKER_MODE", "seed"),
		MockDataCount:      getEnvInt("MOCK_DATA_COUNT", 100),
		MongoDBURI:         getEnv("MONGODB_URI", "mongodb://localhost:27017"),
		MongoDBName:        getEnv("MONGODB_DB", "testboot_db"),
		MongoDBMaxPoolSize: getEnvUint64("MONGODB_MAX_POOL_SIZE", 100),
		RabbitMQURI:        getEnv("RABBITMQ_URI", "amqp://guest:guest@localhost:5672/"),
		RabbitMQQueue:      getEnv("RABBITMQ_QUEUE", "worker_queue"),
		ValkeyAddr:         getEnv("VALKEY_ADDR", "localhost:6379"),
		ValkeyDB:           getEnvInt("VALKEY_DB", 0),
		SeedHTTPTimeoutSec: getEnvInt("SEED_HTTP_TIMEOUT_SEC", 1800),
		SeedBatchSize:      getEnvInt("SEED_BATCH_SIZE", 1000),
		SeedTargetSizeMB:   getEnvInt("SEED_TARGET_SIZE_MB", 0),
	}

	if strings.TrimSpace(cfg.MongoDBURI) == "" {
		return nil, fmt.Errorf("MONGODB_URI is required")
	}
	if strings.TrimSpace(cfg.RabbitMQURI) == "" {
		return nil, fmt.Errorf("RABBITMQ_URI is required")
	}
	if strings.TrimSpace(cfg.ValkeyAddr) == "" {
		return nil, fmt.Errorf("VALKEY_ADDR is required")
	}

	return cfg, nil
}

func (cfg *Config) buildMongoDBURI() string {
	return cfg.MongoDBURI
}

func (cfg *Config) buildRabbitMQURI() string {
	return cfg.RabbitMQURI
}

func getEnv(key, defaultValue string) string {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return strings.TrimSpace(value)
}

func getEnvInt(key string, defaultValue int) int {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	intVal, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return defaultValue
	}
	return intVal
}

func getEnvUint64(key string, defaultValue uint64) uint64 {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	u, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
	if err != nil {
		return defaultValue
	}
	return u
}
