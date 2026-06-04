// Command cgiserver is a minimal HTTP server that executes CGI scripts.
// It replaces busybox httpd for db-dumper, eliminating the need for
// busybox-extras and QEMU during cross-platform Docker builds.
package main

import (
	"log"
	"net/http"
	"net/http/cgi" //nolint:gosec // G504: CGI is the entire point of this binary; CVE-2016-5386 (Httpoxy) was fixed in Go 1.6.3 and we ship on Go 1.26+.
	"os"
	"path/filepath"
	"strings"
	"time"
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

	mux := http.NewServeMux()

	mux.HandleFunc("/cgi-bin/", func(w http.ResponseWriter, r *http.Request) {
		script := filepath.Base(r.URL.Path)
		path := filepath.Join(cgiDir, script)

		// Guard against path traversal: filepath.Base can still yield ".."
		// (e.g. a request path of "/cgi-bin/.."), so confirm the resolved
		// path stays inside cgiDir before touching the filesystem.
		if !strings.HasPrefix(path, filepath.Clean(cgiDir)+string(os.PathSeparator)) {
			http.NotFound(w, r)
			return
		}

		if _, err := os.Stat(path); err != nil { //nolint:gosec // G703: path is constrained to cgiDir by the prefix check above.
			http.NotFound(w, r)
			return
		}

		handler := &cgi.Handler{Path: path, Dir: cgiDir}
		handler.ServeHTTP(w, r)
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	// G706: addr and cgiDir come from process environment / startup config,
	// not from network input, so log injection is not a concern here.
	log.Printf("cgiserver listening on %s (scripts: %s)", addr, cgiDir) //nolint:gosec // G706: trusted startup config, not user input.

	srv := &http.Server{
		Addr:    addr,
		Handler: mux,
		// CGI scripts can run long (pg_dump on large DBs), so the body-write
		// timeouts (WriteTimeout / IdleTimeout) are intentionally generous.
		// ReadHeaderTimeout is the slowloris guard and stays small.
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      0, // CGI may stream gigabytes; let the script finish.
		IdleTimeout:       60 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
