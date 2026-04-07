package main

import (
	"context"
	"log/slog"

	"github.com/redis/go-redis/v9"
	"github.com/streadway/amqp"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// MongoDBManager handles connections and operations to MongoDB (multi-collection).
type MongoDBManager struct {
	client *mongo.Client
	db     *mongo.Database
}

func (m *MongoDBManager) Connect(ctx context.Context, uri string, dbName string, maxPoolSize uint64) error {
	slog.Debug("mongodb connecting", "uri", uri, "db", dbName, "max_pool_size", maxPoolSize)

	opts := options.Client().ApplyURI(uri)
	if maxPoolSize > 0 {
		opts.SetMaxPoolSize(maxPoolSize)
	}

	client, err := mongo.Connect(ctx, opts)
	if err != nil {
		slog.Error("mongodb connect failed", "err", err)
		return err
	}

	if err = client.Ping(ctx, nil); err != nil {
		slog.Error("mongodb ping failed", "err", err)
		client.Disconnect(ctx)
		return err
	}

	m.client = client
	m.db = client.Database(dbName)

	slog.Info("mongodb connected", "db", dbName)
	return nil
}

// indexSpec returns unique index key field for a collection name.
func indexSpecForCollection(name string) (key string, ok bool) {
	switch name {
	case "users":
		return "user_id", true
	case "orders":
		return "order_id", true
	case "events":
		return "event_id", true
	case "metrics":
		return "metric_id", true
	default:
		return "", false
	}
}

func (m *MongoDBManager) EnsureCollection(ctx context.Context, name string) error {
	if m.db == nil {
		return nil
	}

	slog.Debug("mongodb ensuring collection", "collection", name)

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
		if err := m.db.CreateCollection(ctx, name); err != nil {
			slog.Warn("mongodb create collection warning", "err", err)
		}
		slog.Info("mongodb collection created", "collection", name)
	} else {
		slog.Debug("mongodb collection already exists", "collection", name)
	}

	key, ok := indexSpecForCollection(name)
	if !ok {
		return nil
	}

	coll := m.db.Collection(name)
	indexModel := mongo.IndexModel{
		Keys:    bson.D{{Key: key, Value: 1}},
		Options: options.Index().SetUnique(true),
	}
	if _, err := coll.Indexes().CreateOne(ctx, indexModel); err != nil {
		slog.Warn("mongodb create index warning", "collection", name, "key", key, "err", err)
	}

	return nil
}

// InsertMany inserts into the named collection (unordered bulk).
func (m *MongoDBManager) InsertMany(ctx context.Context, collectionName string, docs []interface{}) (int, error) {
	if m.db == nil || len(docs) == 0 {
		return 0, nil
	}

	coll := m.db.Collection(collectionName)
	opts := options.InsertMany().SetOrdered(false)

	result, err := coll.InsertMany(ctx, docs, opts)
	if err != nil {
		slog.Error("mongodb insert many failed", "collection", collectionName, "err", err)
		return 0, err
	}

	return len(result.InsertedIDs), nil
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

// Count returns estimated document count for a collection.
func (m *MongoDBManager) Count(ctx context.Context, collectionName string) (int64, error) {
	if m.db == nil {
		return 0, nil
	}

	coll := m.db.Collection(collectionName)
	count, err := coll.EstimatedDocumentCount(ctx)
	if err != nil {
		slog.Error("mongodb count failed", "collection", collectionName, "err", err)
		return 0, err
	}

	return count, nil
}

// Connected reports whether MongoDB is usable.
func (m *MongoDBManager) Connected() bool {
	return m != nil && m.db != nil
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
		queueName,
		true,
		false,
		false,
		false,
		nil,
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

	result := map[string]string{
		"info": info[:min(len(info), 100)],
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
