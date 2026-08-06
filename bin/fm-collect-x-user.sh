#!/usr/bin/env bash
# Collect a public X user's posts by status id into the spoodifier social pack (study only).
# Timeline is login-walled; pass status IDs or --url. Uses api.fxtwitter.com + curl for media.
#
# Usage:
#   fm-collect-x-user.sh <handle>
#   fm-collect-x-user.sh <handle> <status-id> [<status-id>...]
#   fm-collect-x-user.sh <handle> --url 'https://x.com/<handle>/status/<id>'
#
# Examples:
#   fm-collect-x-user.sh dbullonsol
#   fm-collect-x-user.sh dbullonsol 2077650018291339564
#   fm-collect-x-user.sh dbullonsol --url 'https://x.com/dbullonsol/status/2077650018291339564'
#   fm-collect-x-user.sh fizzychats   # same as fm-collect-fizzychats.sh
#
# Reads status IDs from the handle's watch-ids.txt and any passed arguments.
# Fetches post JSON from ${FM_X_API:-https://api.fxtwitter.com}/<handle>/status/<id>.
# Downloads media and writes posts-index.json with metadata + local media paths.
# Built-in paths for fizzychats and dbullonsol; generic path for other handles.
#
# Environment:
#   FM_X_API             FxTwitter API base URL (default: https://api.fxtwitter.com)
#   FM_FIZZY_DIR         fizzychats destination (default: data/spoodifier-social-pack/reference-fizzychats)
#   FM_DBULL_X_DIR       dbullonsol destination (default: data/spoodifier-social-pack/reference-dbull)
#   FM_X_COLLECT_DIR     Generic destination (default: data/spoodifier-social-pack/reference-x-<handle>)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${FM_X_API:-https://api.fxtwitter.com}"

if [[ $# -lt 1 ]]; then
  sed -n '2,10p' "$0"
  exit 1
fi

HANDLE="${1#@}"
shift

case "$HANDLE" in
  fizzychats)
    DEST="${FM_FIZZY_DIR:-$ROOT/data/spoodifier-social-pack/reference-fizzychats}"
    POSTS="$DEST/posts"
    MEDIA="$DEST/media"
    INDEX="$DEST/posts-index.json"
    WATCH="$DEST/watch-ids.txt"
    ;;
  dbullonsol)
    DEST="${FM_DBULL_X_DIR:-$ROOT/data/spoodifier-social-pack/reference-dbull}"
    POSTS="$DEST/x-posts"
    MEDIA="$DEST/x-media"
    INDEX="$DEST/x-posts-index.json"
    WATCH="$DEST/x-watch-ids.txt"
    ;;
  *)
    DEST="${FM_X_COLLECT_DIR:-$ROOT/data/spoodifier-social-pack/reference-x-$HANDLE}"
    POSTS="$DEST/posts"
    MEDIA="$DEST/media"
    INDEX="$DEST/posts-index.json"
    WATCH="$DEST/watch-ids.txt"
    ;;
esac

mkdir -p "$POSTS" "$MEDIA" "$DEST"

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
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      ids+=("$1")
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

if [[ ${#ids[@]} -eq 0 ]]; then
  echo "no status ids (edit $WATCH or pass ids/--url)" >&2
  exit 1
fi

_ids_deduped=()
while IFS= read -r _id; do
  [[ -n "$_id" ]] && _ids_deduped+=("$_id")
done < <(printf '%s\n' "${ids[@]}" | awk '!a[$0]++')
ids=("${_ids_deduped[@]}")

ok=0
fail=0
for id in "${ids[@]}"; do
  out="$POSTS/${id}.json"
  if ! curl -sL --max-time 25 "${API}/${HANDLE}/status/${id}" -o "$out"; then
    echo "fail fetch $id" >&2
    fail=$((fail + 1))
    continue
  fi
  code="$(python3 -c "import json;print(json.load(open('$out')).get('code',0))" 2>/dev/null || echo 0)"
  if [[ "$code" != "200" ]]; then
    echo "fail $id code=$code" >&2
    rm -f "$out"
    fail=$((fail + 1))
    continue
  fi
  author="$(python3 -c "import json;print(json.load(open('$out'))['tweet']['author']['screen_name'])" 2>/dev/null || echo '')"
  if [[ "$author" != "$HANDLE" ]]; then
    echo "skip $id author=$author (wanted $HANDLE)" >&2
    rm -f "$out"
    fail=$((fail + 1))
    continue
  fi
  if [[ -f "$WATCH" ]] && ! grep -qE "^${id}$" "$WATCH" 2>/dev/null; then
    echo "$id" >>"$WATCH"
  elif [[ ! -f "$WATCH" ]]; then
    echo "$id" >>"$WATCH"
  fi
  ok=$((ok + 1))
  echo "ok $id"
done

python3 - "$POSTS" "$MEDIA" "$INDEX" "$WATCH" <<'PY'
import json, subprocess, sys
from pathlib import Path
posts_dir, media_dir, index_path, watch_path = map(Path, sys.argv[1:5])
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
        # relative path depends on media dir name
        rel = f"{media_dir.name}/{name}"
        saved.append(rel)
    rows.append(
        {
            "id": tid,
            "url": t.get("url") or f"https://x.com/{t.get('author',{}).get('screen_name','')}/status/{tid}",
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
watch_path.write_text("\n".join(r["id"] for r in rows) + ("\n" if rows else ""))
print(f"index {len(rows)} posts, media files {len(list(media_dir.glob('*')))}")
PY

echo "done ok=$ok fail=$fail dest=$DEST handle=@$HANDLE"
