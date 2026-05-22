#!/bin/sh
# Shared validation helpers for db-dumper scripts.
# Sourced by dump.sh and entrypoint.sh at runtime.
#
# Return-value contract:
#   All validate_* functions return 0 on success (input is valid)
#   and 1 on failure (input is invalid). On failure a diagnostic
#   message is printed to stderr.

validate_no_control_chars() {
  case "$2" in
    *[[:cntrl:]]*)
      printf 'level=error msg="env var contains control characters" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
  return 0
}

validate_identifier() {
  case "$2" in
    "")
      printf 'level=error msg="%s is empty"\n' "$1" >&2
      return 1
      ;;
    -*)
      printf 'level=error msg="%s must not start with -" %s="%s"\n' \
        "$1" "$1" "$2" >&2
      return 1
      ;;
    *[!a-zA-Z0-9_-]*)
      printf 'level=error msg="%s contains invalid characters" %s="%s"\n' \
        "$1" "$1" "$2" >&2
      return 1
      ;;
  esac
  return 0
}

validate_spec_format() {
  _colons=$(printf '%s' "$1" | tr -cd ':')
  if [ "${#_colons}" -ne 2 ]; then
    printf 'level=error msg="invalid spec format" spec="%s"\n' "$1" >&2
    return 1
  fi
  return 0
}

validate_numeric() {
  case "$2" in
    '' | *[!0-9]*)
      printf 'level=error msg="env var must be a positive integer" var=%s value="%s"\n' "$1" "$2" >&2
      return 1
      ;;
  esac
  return 0
}
