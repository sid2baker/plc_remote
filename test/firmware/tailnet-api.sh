#!/bin/sh
set -eu

command="${1:?usage: tailnet-api.sh issue|cleanup ...}"
shift

api="https://api.tailscale.com"
client_id="${TS_OAUTH_CLIENT_ID:?set TS_OAUTH_CLIENT_ID}"
client_secret="${TS_OAUTH_SECRET:?set TS_OAUTH_SECRET}"

oauth_token() {
  curl --fail --silent --show-error --max-time 30 \
    --user "$client_id:$client_secret" \
    --data grant_type=client_credentials \
    "$api/api/v2/oauth/token" | jq -r .access_token
}

case "$command" in
  issue)
    hostname="${1:?hostname required}"
    tags="${2:?tags required}"
    payload="${3:?payload path required}"
    state="${4:?state path required}"

    token="$(oauth_token)"
    tags_json="$(printf '%s\n' "$tags" | tr ',' '\n' | jq -Rsc 'split("\n") | map(select(length > 0))')"
    printf '%s' "$tags_json" | jq -e 'length > 0 and all(.[]; startswith("tag:"))' >/dev/null

    response="$(jq -n --argjson tags "$tags_json" '{
      capabilities: {devices: {create: {
        reusable: false,
        ephemeral: true,
        preauthorized: true,
        tags: $tags
      }}},
      expirySeconds: 900
    }' | curl --fail --silent --show-error --max-time 30 \
      --request POST \
      --header "Authorization: Bearer $token" \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      "$api/api/v2/tailnet/-/keys")"

    umask 077
    mkdir -p "$(dirname "$payload")"
    printf '%s' "$response" | jq --arg hostname "$hostname" --argjson tags "$tags_json" \
      '{auth_key: .key, hostname: $hostname, tags: $tags}' >"$payload"
    printf '%s' "$response" | jq '{key_id: .id}' >"$state"
    chmod 600 "$payload" "$state"
    echo "Created one-use tailnet enrollment payload"
    ;;

  cleanup)
    payload="${1:?payload path required}"
    state="${2:?state path required}"

    if [ -f "$state" ]; then
      token="$(oauth_token)"
      key_id="$(jq -r '.key_id // empty' "$state")"
      if [ -n "$key_id" ]; then
        curl --fail --silent --show-error --max-time 30 \
          --request DELETE \
          --header "Authorization: Bearer $token" \
          "$api/api/v2/tailnet/-/keys/$key_id" >/dev/null 2>&1 || true
      fi
    fi

    rm -f "$payload" "$state"
    echo "Removed disposable tailnet key; the ephemeral gateway expires automatically"
    ;;

  *)
    echo "usage: tailnet-api.sh issue HOSTNAME TAGS PAYLOAD STATE | cleanup PAYLOAD STATE" >&2
    exit 2
    ;;
esac
