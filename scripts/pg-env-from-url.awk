# =============================================================================
# Turn a postgres:// URL on stdin into libpq environment variables
# =============================================================================
#
# psql accepts a connection URL only as an argument, where any process
# listing (and any agent that records command lines) can read the password.
# libpq reads PGHOST, PGPASSWORD and friends from the environment instead, so
# `eve-infra db status` and `db connect` pipe DATABASE_URL through this
# program inside their psql pod and run psql with no connection arguments:
#
#   pgenv="$(printf '%s' "$DATABASE_URL" | LC_ALL=C awk -f pg-env-from-url.awk)"
#   eval "$pgenv"
#
# It prints `export NAME='value'` lines, quoted for eval. Percent-encoded
# characters are decoded; query parameters libpq also reads from the
# environment (sslmode, host, options, ...) are passed on, and others are
# skipped with a warning. Error messages never include the URL.
# =============================================================================

function fail(message) {
  print "pg-env-from-url: " message > "/dev/stderr"
  failed = 1
  exit 1
}

function hexval(hex,   value, i, digit) {
  value = 0
  for (i = 1; i <= 2; i++) {
    digit = index("0123456789abcdef", tolower(substr(hex, i, 1)))
    if (digit == 0) return -1
    value = value * 16 + digit - 1
  }
  return value
}

function decode(text,   out, i, ch, value) {
  out = ""
  for (i = 1; i <= length(text); i++) {
    ch = substr(text, i, 1)
    if (ch == "%" && (value = hexval(substr(text, i + 1, 2))) >= 0) {
      out = out sprintf("%c", value)
      i += 2
    } else {
      out = out ch
    }
  }
  return out
}

function emit(name, value) {
  if (value == "") return
  gsub(/'/, "'\\''", value)
  printf "export %s='%s'\n", name, value
}

BEGIN {
  count = split("host=PGHOST port=PGPORT user=PGUSER password=PGPASSWORD dbname=PGDATABASE " \
    "sslmode=PGSSLMODE sslrootcert=PGSSLROOTCERT sslcert=PGSSLCERT sslkey=PGSSLKEY sslcrl=PGSSLCRL " \
    "options=PGOPTIONS application_name=PGAPPNAME connect_timeout=PGCONNECT_TIMEOUT " \
    "target_session_attrs=PGTARGETSESSIONATTRS channel_binding=PGCHANNELBINDING " \
    "gssencmode=PGGSSENCMODE sslnegotiation=PGSSLNEGOTIATION", pairs, " ")
  for (i = 1; i <= count; i++) {
    split(pairs[i], pair, "=")
    env_for[pair[1]] = pair[2]
  }
}

{ url = url (NR > 1 ? "\n" : "") $0 }

END {
  if (failed) exit 1
  if (!sub(/^postgres(ql)?:\/\//, "", url)) fail("DATABASE_URL is not a postgres:// or postgresql:// URL")

  query = ""
  if ((at = index(url, "?")) > 0) { query = substr(url, at + 1); url = substr(url, 1, at - 1) }
  dbname = ""
  if ((at = index(url, "/")) > 0) { dbname = substr(url, at + 1); url = substr(url, 1, at - 1) }

  # Credentials end at the last "@", so an unencoded "@" in a password works.
  user = ""; password = ""
  if (match(url, /.*@/)) {
    auth = substr(url, 1, RLENGTH - 1)
    url = substr(url, RLENGTH + 1)
    user = auth
    if ((at = index(auth, ":")) > 0) { user = substr(auth, 1, at - 1); password = substr(auth, at + 1) }
  }

  host = url; port = ""
  if (index(host, ",") > 0) fail("multi-host DATABASE_URLs are not supported")
  if (substr(host, 1, 1) == "[") {
    at = index(host, "]")
    if (at == 0) fail("DATABASE_URL has an unclosed IPv6 host")
    rest = substr(host, at + 1)
    host = substr(host, 2, at - 2)
    if (rest ~ /^:[0-9]+$/) port = substr(rest, 2)
    else if (rest != "") fail("DATABASE_URL has an invalid port")
  } else if (match(host, /:[0-9]*$/)) {
    port = substr(host, RSTART + 1)
    host = substr(host, 1, RSTART - 1)
  }

  emit("PGHOST", decode(host))
  emit("PGPORT", port)
  emit("PGUSER", decode(user))
  emit("PGPASSWORD", decode(password))
  emit("PGDATABASE", decode(dbname))

  # Query parameters override the parts above, as they do in libpq.
  count = split(query, params, "&")
  for (i = 1; i <= count; i++) {
    if (params[i] == "") continue
    key = params[i]; value = ""
    if ((at = index(key, "=")) > 0) { value = substr(key, at + 1); key = substr(key, 1, at - 1) }
    key = decode(key)
    if (key in env_for) emit(env_for[key], decode(value))
    else print "pg-env-from-url: ignoring unsupported URL parameter " key > "/dev/stderr"
  }
}
