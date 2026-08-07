#!/usr/bin/env bash
# Collect @fizzychats posts + media into the spoodifier social pack (study only).
# X timeline is login-walled; discovery = IDs/URLs. Uses api.fxtwitter.com + curl for media.
#
# Usage:
#   fm-collect-fizzychats.sh              # harvest watch-ids.txt
#   fm-collect-fizzychats.sh 123 456      # also add these status ids
#   fm-collect-fizzychats.sh --url 'https://x.com/fizzychats/status/123'
#
# Reads status IDs from ${FM_FIZZY_DIR}/watch-ids.txt and any passed arguments.
# Fetches post JSON from ${FM_FIZZY_API:-https://api.fxtwitter.com}/fizzychats/status/<id>.
# Downloads media and writes posts-index.json with metadata + local media paths.
#
# Environment:
#   FM_FIZZY_DIR     Destination directory (default: data/spoodifier-social-pack/reference-fizzychats)
#   FM_FIZZY_API     FxTwitter API base URL (default: https://api.fxtwitter.com)
#   FM_FIZZY_HANDLE  X handle to fetch (default: fizzychats)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${FM_FIZZY_DIR:-$ROOT/data/spoodifier-social-pack/reference-fizzychats}"
WATCH="$DEST/watch-ids.txt"
POSTS="$DEST/posts"
MEDIA="$DEST/media"
INDEX="$DEST/posts-index.json"
API="${FM_FIZZY_API:-https://api.fxtwitter.com}"
HANDLE="${FM_FIZZY_HANDLE:-fizzychats}"

mkdir -p "$POSTS" "$MEDIA" "$DEST/profile"

ids=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      shift
      u="${1:-}"
      if [[ "$u" =~ status/([0-9]+) ]]; then
        ids+=("${BASH_REMATCH[1]}")
      else
        echo "could not parse status id from: $u" >&2
        exit 1
      fi
      ;;
    --help|-h)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ids+=("$1")
      else
        echo "not a status id: $1 (expected digits only, or use --url)" >&2
        exit 1
      fi
      ;;
  esac
  shift || true
done

if [[ -f "$WATCH" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[0-9]+$ ]] || continue
    ids+=("$line")
  done <"$WATCH"
fi

# dedupe (portable; no mapfile)
if [[ ${#ids[@]} -eq 0 ]]; then
  echo "no status ids (edit $WATCH or pass ids/--url)" >&2
  exit 1
fi
_ids_deduped=()
while IFS= read -r _id; do
  [[ -n "$_id" ]] && _ids_deduped+=("$_id")
done < <(printf '%s\n' "${ids[@]}" | awk '!a[$0]++')
ids=("${_ids_deduped[@]}")

# ensure profile chrome
if [[ ! -s "$DEST/profile/avatar-400.jpg" ]]; then
  curl -sL --max-time 30 -o "$DEST/profile/avatar-400.jpg" \
    'https://pbs.twimg.com/profile_images/2077894692256026625/AvhtHHgb_400x400.jpg' || true
fi
if [[ ! -s "$DEST/profile/banner-1500x500.jpg" ]]; then
  curl -sL --max-time 30 -o "$DEST/profile/banner-1500x500.jpg" \
    'https://pbs.twimg.com/profile_banners/1952426104217886720/1768866859/1500x500' || true
fi

tmp=""
cleanup_tmp() { [[ -n "$tmp" ]] && rm -f "$tmp"; return 0; }
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT TERM

ok=0
fail=0
for id in "${ids[@]}"; do
  out="$POSTS/${id}.json"
  tmp="$(mktemp "$POSTS/.${id}.XXXXXX")"
  if ! curl -sL --max-time 25 "${API}/${HANDLE}/status/${id}" -o "$tmp"; then
    echo "fail fetch $id" >&2
    rm -f "$tmp"
    fail=$((fail + 1))
    continue
  fi
  code="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("code",0))' "$tmp" 2>/dev/null || echo 0)"
  if [[ "$code" != "200" ]]; then
    echo "fail $id code=$code" >&2
    rm -f "$tmp"
    fail=$((fail + 1))
    continue
  fi
  mv -f "$tmp" "$out"
  # append to watch list if new
  if [[ -f "$WATCH" ]] && ! grep -qE "^${id}$" "$WATCH" 2>/dev/null; then
    echo "$id" >>"$WATCH"
  elif [[ ! -f "$WATCH" ]]; then
    echo "$id" >>"$WATCH"
  fi
  ok=$((ok + 1))
  echo "ok $id"
done

python3 - "$POSTS" "$MEDIA" "$INDEX" <<'PY'
import json, subprocess, sys
from pathlib import Path
posts_dir, media_dir, index_path = map(Path, sys.argv[1:4])
media_dir.mkdir(parents=True, exist_ok=True)
rows = []
for p in sorted(posts_dir.glob("*.json")):
    try:
        d = json.loads(p.read_text())
    except Exception as e:
        print(f"skip bad json {p.name}: {e}", file=sys.stderr)
        continue
    if d.get("code") != 200:
        continue
    t = d["tweet"]
    tid = str(t.get("id") or p.stem)
    media = []
    m = t.get("media") or {}
    for key in ("photos", "all", "videos"):
        for ph in m.get(key) or []:
            if isinstance(ph, dict):
                if ph.get("url"):
                    media.append(ph["url"])
                if ph.get("thumbnail_url"):
                    media.append(ph["thumbnail_url"])
    seen = set()
    media = [u for u in media if not (u in seen or seen.add(u))]
    saved = []
    for i, mu in enumerate(media):
        base = mu.split("?")[0]
        ext = ".jpg"
        if base.endswith(".png"):
            ext = ".png"
        elif base.endswith(".mp4"):
            ext = ".mp4"
        elif base.endswith(".gif"):
            ext = ".gif"
        name = f"{tid}_{i}{ext}"
        dest = media_dir / name
        if not dest.exists() or dest.stat().st_size < 100:
            r = subprocess.run(
                ["curl", "-sL", "--max-time", "60", "-o", str(dest), mu],
                capture_output=True,
            )
            if r.returncode != 0 or not dest.exists() or dest.stat().st_size < 100:
                print(f"fail media {name}", file=sys.stderr)
                continue
            print(f"dl {name} {dest.stat().st_size}")
        saved.append(f"media/{name}")
    rows.append(
        {
            "id": tid,
            "url": t.get("url") or f"https://x.com/fizzychats/status/{tid}",
            "created_at": t.get("created_at"),
            "text": t.get("text"),
            "likes": t.get("likes"),
            "retweets": t.get("retweets"),
            "replies": t.get("replies"),
            "views": t.get("views"),
            "media_files": saved,
            "media_urls": media,
        }
    )
index_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n")
print(f"index {len(rows)} posts, media files {len(list(media_dir.glob('*')))}")
PY

echo "done ok=$ok fail=$fail dest=$DEST"
