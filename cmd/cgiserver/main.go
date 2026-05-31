// Command cgiserver is a minimal HTTP server that executes CGI scripts.
// It replaces busybox httpd for db-dumper, eliminating the need for
// busybox-extras and QEMU during cross-platform Docker builds.
package main

import (
	"log"
	"net/http"
	"net/http/cgi"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	addr := ":9847"
	cgiDir := "/srv/cgi-bin"

	if v := os.Getenv("CGI_DIR"); v != "" {
		cgiDir = v
	}
	if v := os.Getenv("LISTEN_ADDR"); v != "" {
		addr = v
	}

	http.HandleFunc("/cgi-bin/", func(w http.ResponseWriter, r *http.Request) {
		script := filepath.Base(r.URL.Path)
		path := filepath.Join(cgiDir, script)

		// Guard against path traversal: filepath.Base can still yield ".."
		// (e.g. a request path of "/cgi-bin/.."), so confirm the resolved
		// path stays inside cgiDir before touching the filesystem.
		if !strings.HasPrefix(path, filepath.Clean(cgiDir)+string(os.PathSeparator)) {
			http.NotFound(w, r)
			return
		}

		if _, err := os.Stat(path); err != nil {
			http.NotFound(w, r)
			return
		}

		handler := &cgi.Handler{Path: path, Dir: cgiDir}
		handler.ServeHTTP(w, r)
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	log.Printf("cgiserver listening on %s (scripts: %s)", addr, cgiDir)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}
