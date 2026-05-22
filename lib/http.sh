#!/bin/sh
# HTTP response helpers for CGI scripts (busybox httpd).

# respond: emit an HTTP response.
# Usage: respond <status_line> <content_type> <body>
# If status_line is empty, no Status header is emitted (implicit 200).
respond() {
  [ -n "$1" ] && printf 'Status: %s\r\n' "$1"
  printf 'Content-Type: %s\r\n\r\n' "$2"
  printf '%s' "$3"
}

# respond_error: emit an HTTP error response and exit.
# Usage: respond_error <status_line> <body_text>
respond_error() {
  respond "$1" "text/plain" "$2
"
  exit 0
}
