package main

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	ListenAddr       string
	LogLevel         string
	LogFormat        string
	LogFile          string
	WorkerMode       string
	MockDataCount    int
	MongoDBHost      string
	MongoDBPort      int
	MongoDBUsername  string
	MongoDBPassword  string
	MongoDBName      string
	MongoDBReplicaSet string
	RabbitMQHost     string
	RabbitMQPort     int
	RabbitMQUsername string
	RabbitMQPassword string
	RabbitMQVHost    string
	RabbitMQQueue    string
	ValkeyAddr       string
	ValkeyDB         int
}

func loadConfig() (*Config, error) {
	cfg := &Config{
		ListenAddr:       getEnv("LISTEN_ADDR", ":8001"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
		LogFormat:        getEnv("LOG_FORMAT", "text"),
		LogFile:          getEnv("LOG_FILE", ""),
		WorkerMode:       getEnv("WORKER_MODE", "seed"),
		MockDataCount:    getEnvInt("MOCK_DATA_COUNT", 100),
		MongoDBHost:      getEnv("MONGODB_HOST", "localhost"),
		MongoDBPort:      getEnvInt("MONGODB_PORT", 27017),
		MongoDBUsername:  getEnv("MONGODB_USERNAME", ""),
		MongoDBPassword:  getEnv("MONGODB_PASSWORD", ""),
		MongoDBName:      getEnv("MONGODB_DB", "testboot_db"),
		MongoDBReplicaSet: getEnv("MONGODB_REPLICA_SET", ""),
		RabbitMQHost:      getEnv("RABBITMQ_HOST", "localhost"),
		RabbitMQPort:      getEnvInt("RABBITMQ_PORT", 5672),
		RabbitMQUsername:  getEnv("RABBITMQ_USERNAME", "guest"),
		RabbitMQPassword:  getEnv("RABBITMQ_PASSWORD", "guest"),
		RabbitMQVHost:     getEnv("RABBITMQ_VHOST", "/"),
		RabbitMQQueue:    getEnv("RABBITMQ_QUEUE", "worker_queue"),
		ValkeyAddr:       getEnv("VALKEY_ADDR", "localhost:6379"),
		ValkeyDB:         getEnvInt("VALKEY_DB", 0),
	}

	// Validate required config
	if cfg.MongoDBHost == "" {
		return nil, fmt.Errorf("MONGODB_HOST is required")
	}
	if cfg.RabbitMQHost == "" {
		return nil, fmt.Errorf("RABBITMQ_HOST is required")
	}
	if cfg.ValkeyAddr == "" {
		return nil, fmt.Errorf("VALKEY_ADDR is required")
	}

	return cfg, nil
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

// buildMongoDBURI constructs a properly formatted MongoDB URI with URL-encoded password
func (c *Config) buildMongoDBURI() string {
	hostPort := fmt.Sprintf("%s:%d", c.MongoDBHost, c.MongoDBPort)

	var uri string
	if c.MongoDBUsername != "" && c.MongoDBPassword != "" {
		// URL encode the password to handle special characters
		encodedPassword := url.QueryEscape(c.MongoDBPassword)
		uri = fmt.Sprintf("mongodb://%s:%s@%s", c.MongoDBUsername, encodedPassword, hostPort)
	} else {
		uri = fmt.Sprintf("mongodb://%s", hostPort)
	}

	// Add replica set if specified
	if c.MongoDBReplicaSet != "" {
		uri += fmt.Sprintf("/?replicaSet=%s", c.MongoDBReplicaSet)
	}

	return uri
}

// buildRabbitMQURI constructs a properly formatted RabbitMQ AMQP URI
func (c *Config) buildRabbitMQURI() string {
	// URL encode credentials to handle special characters
	encodedUsername := url.QueryEscape(c.RabbitMQUsername)
	encodedPassword := url.QueryEscape(c.RabbitMQPassword)

	// Build URI: amqp://user:pass@host:port/vhost
	uri := fmt.Sprintf("amqp://%s:%s@%s:%d%s",
		encodedUsername,
		encodedPassword,
		c.RabbitMQHost,
		c.RabbitMQPort,
		c.RabbitMQVHost)

	return uri
}
