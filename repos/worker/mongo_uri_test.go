package main

import (
	"strings"
	"testing"
)

func TestEscapeMongoDBCredentials_SlashInPassword(t *testing.T) {
	in := "mongodb://appuser:sec/ret@localhost:27017/testboot_db?authSource=admin"
	out := escapeMongoDBCredentials(in)
	if strings.Contains(out, "sec/ret") {
		t.Fatalf("password should be encoded, got %q", out)
	}
	if !strings.Contains(out, "sec%2Fret") {
		t.Fatalf("expected %%2F in password, got %q", out)
	}
	if !strings.HasPrefix(out, "mongodb://") {
		t.Fatalf("expected mongodb:// prefix, got %q", out)
	}
}

func TestEscapeMongoDBCredentials_AlreadyEncoded(t *testing.T) {
	in := "mongodb://u:p%2Fw@localhost:27017/"
	out := escapeMongoDBCredentials(in)
	// Must not double-encode (%2F -> %252F)
	if strings.Contains(out, "%252F") {
		t.Fatalf("double-encoded password: %q", out)
	}
	if !strings.Contains(out, "p%2Fw") {
		t.Fatalf("expected single encoding, got %q", out)
	}
}

func TestEscapeMongoDBCredentials_Srv(t *testing.T) {
	in := "mongodb+srv://user:pa:ss@cluster.example.net/?retryWrites=true"
	out := escapeMongoDBCredentials(in)
	if strings.Contains(out, "pa:ss@") {
		t.Fatalf("colon in password must be encoded: %q", out)
	}
}

func TestEscapeMongoDBCredentials_NoCredentials(t *testing.T) {
	in := "mongodb://localhost:27017/db"
	if escapeMongoDBCredentials(in) != in {
		t.Fatal("unchanged when no userinfo")
	}
}
