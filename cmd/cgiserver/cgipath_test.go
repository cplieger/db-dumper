package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// withinDir reports whether child resolves to a location inside parent,
// derived independently of resolveCGIScriptPath's own prefix check so the
// fuzz oracle does not simply re-run the implementation. It uses filepath.Rel
// as a second source of truth: a path is contained iff its relative form does
// not climb out with "..".
func withinDir(parent, child string) bool {
	rel, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(child))
	if err != nil {
		return false
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false
	}
	return true
}

func TestResolveCGIScriptPath(t *testing.T) {
	tests := []struct {
		name     string
		cgiDir   string
		urlPath  string
		wantPath string
		wantOK   bool
	}{
		{
			name:     "normal script",
			cgiDir:   "/srv/cgi-bin",
			urlPath:  "/cgi-bin/dump",
			wantPath: "/srv/cgi-bin/dump",
			wantOK:   true,
		},
		{
			name:     "health script",
			cgiDir:   "/srv/cgi-bin",
			urlPath:  "/cgi-bin/health",
			wantPath: "/srv/cgi-bin/health",
			wantOK:   true,
		},
		{
			name:    "parent traversal collapses to dotdot",
			cgiDir:  "/srv/cgi-bin",
			urlPath: "/cgi-bin/..",
			wantOK:  false,
		},
		{
			name:    "deep traversal resolves to base only",
			cgiDir:  "/srv/cgi-bin",
			urlPath: "/cgi-bin/../../etc/passwd",
			// filepath.Base yields "passwd", which is a valid in-dir script
			// name; the guard does not reject it because it never escapes.
			wantPath: "/srv/cgi-bin/passwd",
			wantOK:   true,
		},
		{
			name:    "bare cgi-bin resolves to filename inside dir",
			cgiDir:  "/srv/cgi-bin",
			urlPath: "/cgi-bin/",
			// filepath.Base strips the trailing slash and yields "cgi-bin",
			// an in-dir filename; the guard accepts it (os.Stat 404s later).
			wantPath: "/srv/cgi-bin/cgi-bin",
			wantOK:   true,
		},
		{
			name:    "root path",
			cgiDir:  "/srv/cgi-bin",
			urlPath: "/",
			wantOK:  false,
		},
		{
			name:    "empty path",
			cgiDir:  "/srv/cgi-bin",
			urlPath: "",
			wantOK:  false,
		},
		{
			name:     "trailing slash on cgiDir",
			cgiDir:   "/srv/cgi-bin/",
			urlPath:  "/cgi-bin/dump",
			wantPath: "/srv/cgi-bin/dump",
			wantOK:   true,
		},
		{
			name:    "relative cgiDir rejected",
			cgiDir:  "srv/cgi-bin",
			urlPath: "/cgi-bin/dump",
			// A non-absolute cgiDir fails closed: the containment check is
			// only sound against an absolute root.
			wantOK: false,
		},
		{
			name:    "dotdot cgiDir rejected",
			cgiDir:  "..",
			urlPath: "..",
			wantOK:  false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotPath, gotOK := resolveCGIScriptPath(tc.cgiDir, tc.urlPath)

			if gotOK != tc.wantOK {
				t.Errorf("resolveCGIScriptPath(%q, %q) ok = %v, want %v", tc.cgiDir, tc.urlPath, gotOK, tc.wantOK)
			}
			if gotOK && gotPath != tc.wantPath {
				t.Errorf("resolveCGIScriptPath(%q, %q) path = %q, want %q", tc.cgiDir, tc.urlPath, gotPath, tc.wantPath)
			}
		})
	}
}

// FuzzResolveCGIScriptPath drives the path-traversal guard with arbitrary
// untrusted request paths AND directory roots, and asserts the security
// invariant: whenever the function accepts a path, (1) cgiDir was absolute,
// (2) the path resolves to a location strictly inside cgiDir, and (3) its
// parent is exactly cgiDir (the result is always cgiDir joined with a single
// element). A rejection must never return a path.
//
// In production cgiDir is trusted startup config and always absolute, but it
// is fuzzed here too so the guard's fail-closed behavior on a misconfigured
// (relative or traversal) CGI_DIR is exercised rather than assumed. The
// invariants above hold for ANY (cgiDir, urlPath) pair, which is why the
// directory root can be fuzzed without producing false counterexamples.
func FuzzResolveCGIScriptPath(f *testing.F) {
	seeds := []struct {
		cgiDir  string
		urlPath string
	}{
		{"/srv/cgi-bin", "/cgi-bin/dump"},
		{"/srv/cgi-bin", "/cgi-bin/health"},
		{"/srv/cgi-bin", "/cgi-bin/.."},
		{"/srv/cgi-bin", "/cgi-bin/../../etc/passwd"},
		{"/srv/cgi-bin", "/cgi-bin/%2e%2e/secret"},
		{"/srv/cgi-bin", "/cgi-bin/..%2f..%2fetc"},
		{"/srv/cgi-bin", "/cgi-bin/foo/bar/baz"},
		{"/srv/cgi-bin", "/cgi-bin/\x00null"},
		{"/srv/cgi-bin", "/cgi-bin/.../...//"},
		{"/srv/cgi-bin", "//cgi-bin//dump//"},
		{"/srv/cgi-bin", "/cgi-bin/"},
		{"/srv/cgi-bin", "/"},
		{"/srv/cgi-bin", ""},
		{"/srv/cgi-bin/", "/cgi-bin/dump"},
		{"/srv/cgi-bin/..", "/cgi-bin/dump"},
		{"/", "/cgi-bin/dump"},
		{"srv/cgi-bin", "/cgi-bin/dump"},
		{"", "/cgi-bin/dump"},
		{"..", ".."},
		{".", "."},
	}
	for _, s := range seeds {
		f.Add(s.cgiDir, s.urlPath)
	}

	f.Fuzz(func(t *testing.T, cgiDir, urlPath string) {
		path, ok := resolveCGIScriptPath(cgiDir, urlPath)

		if !ok {
			if path != "" {
				t.Errorf("resolveCGIScriptPath(%q, %q) returned path %q on rejection, want empty", cgiDir, urlPath, path)
			}
			return
		}

		if !filepath.IsAbs(cgiDir) {
			t.Errorf("resolveCGIScriptPath(%q, %q) accepted a non-absolute cgiDir", cgiDir, urlPath)
		}

		if !withinDir(cgiDir, path) {
			t.Errorf("resolveCGIScriptPath(%q, %q) = %q escapes cgiDir", cgiDir, urlPath, path)
		}

		if parent := filepath.Dir(path); parent != filepath.Clean(cgiDir) {
			t.Errorf("resolveCGIScriptPath(%q, %q) = %q has parent %q, want %q",
				cgiDir, urlPath, path, parent, filepath.Clean(cgiDir))
		}
	})
}
