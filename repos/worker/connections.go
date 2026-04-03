package main

import (
	"context"
	"log/slog"
	"net/url"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"github.com/redis/go-redis/v9"
	"github.com/streadway/amqp"
)

// MongoDBManager handles connections and operations to MongoDB
type MongoDBManager struct {
	client     *mongo.Client
	db         *mongo.Database
	collection *mongo.Collection
}

func (m *MongoDBManager) Connect(ctx context.Context, uri string, dbName string) error {
	// URL encode password in URI to handle special characters like '/'
	encodedURI, err := encodeMongoDBPassword(uri)
	if err != nil {
		slog.Error("mongodb uri encoding failed", "err", err, "original_uri", uri)
		return err
	}

	slog.Debug("mongodb connecting", "uri", encodedURI, "db", dbName)

	client, err := mongo.Connect(ctx, options.Client().ApplyURI(encodedURI))
	if err != nil {
		slog.Error("mongodb connect failed", "err", err)
		return err
	}

	// Test connection
	if err = client.Ping(ctx, nil); err != nil {
		slog.Error("mongodb ping failed", "err", err)
		client.Disconnect(ctx)
		return err
	}

	m.client = client
	m.db = client.Database(dbName)
	m.collection = m.db.Collection("users")

	slog.Info("mongodb connected", "db", dbName)
	return nil
}

func (m *MongoDBManager) EnsureCollection(ctx context.Context, name string) error {
	if m.db == nil {
		return nil // Not connected yet
	}

	slog.Debug("mongodb ensuring collection", "collection", name)

	// Check if collection exists
	collections, err := m.db.ListCollectionNames(ctx, bson.M{})
	if err != nil {
		slog.Error("mongodb list collections failed", "err", err)
		return err
	}

	exists := false
	for _, coll := range collections {
		if coll == name {
			exists = true
			break
		}
	}

	if !exists {
		// Create collection
		if err := m.db.CreateCollection(ctx, name); err != nil {
			slog.Warn("mongodb create collection warning", "err", err)
			// Ignore error if collection was just created by another goroutine
		}
		slog.Info("mongodb collection created", "collection", name)
	} else {
		slog.Debug("mongodb collection already exists", "collection", name)
	}

	// Ensure indexes
	indexModel := mongo.IndexModel{
		Keys: bson.D{{Key: "user_id", Value: 1}},
		Options: options.Index().SetUnique(true),
	}

	_, err = m.collection.Indexes().CreateOne(ctx, indexModel)
	if err != nil {
		slog.Warn("mongodb create index warning", "err", err)
	}

	return nil
}

func (m *MongoDBManager) InsertMany(ctx context.Context, docs []interface{}) (int, error) {
	if m.collection == nil {
		return 0, nil
	}

	result, err := m.collection.InsertMany(ctx, docs)
	if err != nil {
		slog.Error("mongodb insert many failed", "err", err)
		return 0, err
	}

	count := len(result.InsertedIDs)
	slog.Info("mongodb inserted documents", "count", count)
	return count, nil
}

func (m *MongoDBManager) Close(ctx context.Context) error {
	if m.client == nil {
		return nil
	}

	slog.Debug("mongodb closing")
	if err := m.client.Disconnect(ctx); err != nil {
		slog.Error("mongodb disconnect failed", "err", err)
		return err
	}
	slog.Info("mongodb closed")
	return nil
}

func (m *MongoDBManager) Count(ctx context.Context) (int64, error) {
	if m.collection == nil {
		return 0, nil
	}

	count, err := m.collection.EstimatedDocumentCount(ctx)
	if err != nil {
		slog.Error("mongodb count failed", "err", err)
		return 0, err
	}

	return count, nil
}

// encodeMongoDBPassword parses MongoDB URI and URL-encodes the password to handle special characters
func encodeMongoDBPassword(uri string) (string, error) {
	// Parse the URI
	u, err := url.Parse(uri)
	if err != nil {
		return "", err
	}

	// Check if URI has user info (username:password)
	if u.User == nil {
		return uri, nil // No password to encode
	}

	// Get username and password
	username := u.User.Username()
	password, ok := u.User.Password()
	if !ok {
		return uri, nil // No password
	}

	// URL encode the password
	encodedPassword := url.QueryEscape(password)

	// Rebuild user info with encoded password
	userInfo := url.UserPassword(username, encodedPassword)

	// Rebuild URI with encoded user info
	u.User = userInfo

	return u.String(), nil
}

// RabbitMQManager handles connections to RabbitMQ
type RabbitMQManager struct {
	conn    *amqp.Connection
	channel *amqp.Channel
	queue   string
}

func (r *RabbitMQManager) Connect(ctx context.Context, uri string, queueName string) error {
	slog.Debug("rabbitmq connecting", "uri", uri)

	conn, err := amqp.Dial(uri)
	if err != nil {
		slog.Error("rabbitmq connect failed", "err", err)
		return err
	}

	channel, err := conn.Channel()
	if err != nil {
		slog.Error("rabbitmq channel failed", "err", err)
		conn.Close()
		return err
	}

	r.conn = conn
	r.channel = channel
	r.queue = queueName

	// Declare queue
	if err := r.EnsureQueue(ctx, queueName); err != nil {
		slog.Warn("rabbitmq ensure queue warning", "err", err)
	}

	slog.Info("rabbitmq connected", "queue", queueName)
	return nil
}

func (r *RabbitMQManager) EnsureQueue(ctx context.Context, queueName string) error {
	if r.channel == nil {
		return nil
	}

	slog.Debug("rabbitmq ensuring queue", "queue", queueName)

	_, err := r.channel.QueueDeclare(
		queueName, // name
		true,      // durable
		false,     // auto-delete
		false,     // exclusive
		false,     // no-wait
		nil,       // arguments
	)
	if err != nil {
		slog.Warn("rabbitmq queue declare warning", "err", err)
		return err
	}

	slog.Info("rabbitmq queue ensured", "queue", queueName)
	return nil
}

func (r *RabbitMQManager) Close() error {
	if r.channel != nil {
		r.channel.Close()
	}
	if r.conn != nil {
		slog.Debug("rabbitmq closing")
		if err := r.conn.Close(); err != nil {
			slog.Error("rabbitmq close failed", "err", err)
			return err
		}
	}
	slog.Info("rabbitmq closed")
	return nil
}

func (r *RabbitMQManager) Status(ctx context.Context) (string, error) {
	if r.conn == nil || r.conn.IsClosed() {
		return "disconnected", nil
	}
	return "connected", nil
}

// ValkeyManager handles connections to Valkey (Redis)
type ValkeyManager struct {
	client *redis.Client
}

func (v *ValkeyManager) Connect(ctx context.Context, addr string, db int) error {
	slog.Debug("valkey connecting", "addr", addr, "db", db)

	client := redis.NewClient(&redis.Options{
		Addr: addr,
		DB:   db,
	})

	// Test connection
	if err := client.Ping(ctx).Err(); err != nil {
		slog.Error("valkey ping failed", "err", err)
		return err
	}

	v.client = client
	slog.Info("valkey connected", "addr", addr, "db", db)
	return nil
}

func (v *ValkeyManager) Ping(ctx context.Context) error {
	if v.client == nil {
		return nil
	}

	cmd := v.client.Ping(ctx)
	return cmd.Err()
}

func (v *ValkeyManager) Info(ctx context.Context) (map[string]string, error) {
	if v.client == nil {
		return map[string]string{}, nil
	}

	cmd := v.client.Info(ctx)
	info, err := cmd.Result()
	if err != nil {
		return map[string]string{}, err
	}

	// Parse info (simplified)
	result := map[string]string{
		"info": info[:min(len(info), 100)], // First 100 chars
	}
	return result, nil
}

func (v *ValkeyManager) Close() error {
	if v.client == nil {
		return nil
	}

	slog.Debug("valkey closing")
	if err := v.client.Close(); err != nil {
		slog.Error("valkey close failed", "err", err)
		return err
	}
	slog.Info("valkey closed")
	return nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
