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

// resolveCGIScriptPath maps an incoming request URL path to the on-disk path
// of the CGI script to execute inside cgiDir. It returns ok=false when the
// resolved path would escape cgiDir.
//
// This is the path-traversal guard for the /cgi-bin/ handler. The request path
// is untrusted network input: filepath.Base can still yield ".." (e.g. a
// request path of "/cgi-bin/.."), so the resolved path is confirmed to stay
// inside cgiDir before the caller touches the filesystem. By construction a
// successful result is always cgiDir joined with a single path element, so its
// parent directory is exactly cgiDir.
//
// cgiDir must be absolute. A relative cgiDir is rejected outright (fail closed)
// because the prefix containment check is only sound against an absolute,
// cleaned root; a misconfigured relative CGI_DIR would otherwise weaken the
// guard. In production cgiDir is always absolute (the /srv/cgi-bin default or
// an absolute CGI_DIR), so this only ever rejects a misconfiguration.
func resolveCGIScriptPath(cgiDir, urlPath string) (string, bool) {
	if !filepath.IsAbs(cgiDir) {
		return "", false
	}
	script := filepath.Base(urlPath)
	path := filepath.Join(cgiDir, script)
	if !strings.HasPrefix(path, filepath.Clean(cgiDir)+string(os.PathSeparator)) {
		return "", false
	}
	return path, true
}

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
		path, ok := resolveCGIScriptPath(cgiDir, r.URL.Path)
		if !ok {
			http.NotFound(w, r)
			return
		}

		// path is constrained to cgiDir by resolveCGIScriptPath above.
		if _, err := os.Stat(path); err != nil {
			http.NotFound(w, r)
			return
		}

		handler := &cgi.Handler{
			Path: path,
			Dir:  cgiDir,
			// InheritEnv forwards env vars from the parent process to CGI
			// scripts. Without this, Go's cgi.Handler only passes the
			// standard CGI vars (REQUEST_METHOD, etc.) and health.sh /
			// dump.sh would see DB_SPECS as empty even when set on the
			// container, breaking both the healthcheck (DB_SPECS_empty)
			// and scheduled dumps.
			InheritEnv: []string{
				"DB_SPECS",
				"DUMP_DIR",
				"DUMP_TIMEOUT",
				"DUMP_FREE_KB_WARN",
			},
		}
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
