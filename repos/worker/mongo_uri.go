package main

import (
	"net/url"
	"strings"
)

// escapeMongoDBCredentials rebuilds a mongodb:// or mongodb+srv:// URI so username and
// password are RFC 3986–encoded. This fixes "unescaped slash in password" and similar
// when MONGODB_URI contains raw special characters (e.g. / : @) in the password.
func escapeMongoDBCredentials(raw string) string {
	out, ok := tryEscapeMongoDBCredentials(raw)
	if !ok {
		return raw
	}
	return out
}

func tryEscapeMongoDBCredentials(raw string) (string, bool) {
	var prefix string
	rest := raw
	switch {
	case strings.HasPrefix(raw, "mongodb+srv://"):
		prefix = "mongodb+srv://"
		rest = raw[len(prefix):]
	case strings.HasPrefix(raw, "mongodb://"):
		prefix = "mongodb://"
		rest = raw[len(prefix):]
	default:
		return raw, false
	}

	at := strings.LastIndex(rest, "@")
	if at < 0 {
		return raw, false
	}

	userinfo := rest[:at]
	hostAndPath := rest[at+1:]

	idx := strings.IndexByte(userinfo, ':')
	if idx < 0 {
		userRaw := userinfo
		userDec := unescapeUserinfoPart(userRaw)
		u := url.User(userDec)
		if u == nil {
			return raw, false
		}
		return prefix + u.String() + "@" + hostAndPath, true
	}

	userRaw := userinfo[:idx]
	passRaw := userinfo[idx+1:]
	userDec := unescapeUserinfoPart(userRaw)
	passDec := unescapeUserinfoPart(passRaw)
	u := url.UserPassword(userDec, passDec)
	return prefix + u.String() + "@" + hostAndPath, true
}

func unescapeUserinfoPart(s string) string {
	if s == "" {
		return s
	}
	dec, err := url.PathUnescape(s)
	if err != nil {
		return s
	}
	return dec
}
