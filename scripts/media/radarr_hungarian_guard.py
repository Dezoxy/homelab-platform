#!/usr/bin/env python3
"""Detect suspicious Radarr language swaps and trigger targeted searches.

The script is conservative by design:

- It only inspects movies touched recently in Radarr history.
- It only considers a movie actionable when the current file looks wrong
  (English-only or neither English nor Hungarian after a recent import/upgrade)
  and an approved Hungarian release is currently visible in Radarr search.
- It respects a search cooldown so recurring runs do not hammer the same movie.

The tool can run directly on the media VM or from another machine with SSH access
to Radarr's ``config.xml`` for API key discovery.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

SUSPICIOUS_IMPORT_EVENTS = {"downloadFolderImported"}
DELETE_EVENTS = {"movieFileDeleted"}
SEARCH_COMMAND_ATTEMPTS = (
    {"name": "MoviesSearch", "movieIds": "__IDS__"},
    {"name": "MoviesSearch", "movieId": "__ID__"},
    {"name": "MovieSearch", "movieIds": "__IDS__"},
    {"name": "MovieSearch", "movieId": "__ID__"},
)
SOURCE_NAME_TO_ID = {
    "unknown": 0,
    "cam": 1,
    "telesync": 2,
    "telecine": 3,
    "workprint": 4,
    "dvd": 5,
    "tv": 6,
    "webdl": 7,
    "webrip": 8,
    "bluray": 9,
}


class ApiError(RuntimeError):
    """Raised when Radarr returns a non-success response."""

    def __init__(self, status: int, body: str) -> None:
        super().__init__(f"Radarr API error {status}: {body}")
        self.status = status
        self.body = body


class RadarrClient:
    """Minimal Radarr API client."""

    def __init__(self, base_url: str, api_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, Any] | None = None,
        payload: dict[str, Any] | list[dict[str, Any]] | None = None,
    ) -> Any:
        url = f"{self.base_url}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query, doseq=True)}"

        headers = {"X-Api-Key": self.api_key}
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode("utf-8")

        request = urllib.request.Request(url, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise ApiError(exc.code, body) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Failed to reach Radarr at {url}: {exc}") from exc

        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def get_movies(self) -> list[dict[str, Any]]:
        return self._request("GET", "/api/v3/movie")

    def get_movie(self, movie_id: int) -> dict[str, Any]:
        return self._request("GET", f"/api/v3/movie/{movie_id}")

    def get_quality_profile(self, profile_id: int) -> dict[str, Any]:
        return self._request("GET", f"/api/v3/qualityprofile/{profile_id}")

    def get_custom_formats(self) -> list[dict[str, Any]]:
        return self._request("GET", "/api/v3/customformat")

    def get_history(self, *, page_size: int) -> list[dict[str, Any]]:
        raise NotImplementedError("Use get_history_since() instead")

    def get_history_since(
        self,
        *,
        since: datetime,
        page_size: int,
        max_pages: int,
    ) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for page in range(1, max_pages + 1):
            payload = self._request(
                "GET",
                "/api/v3/history",
                query={
                    "page": page,
                    "pageSize": page_size,
                    "sortKey": "date",
                    "sortDirection": "descending",
                },
            )
            page_records = payload.get("records", [])
            if not page_records:
                break
            records.extend(page_records)

            oldest_seen: datetime | None = None
            for record in page_records:
                when = parse_datetime(record.get("date"))
                if when is None:
                    continue
                if oldest_seen is None or when < oldest_seen:
                    oldest_seen = when
            if oldest_seen is not None and oldest_seen < since:
                break

            total_records = payload.get("totalRecords")
            if isinstance(total_records, int) and page * page_size >= total_records:
                break
        return records

    def get_releases(self, movie_id: int) -> list[dict[str, Any]]:
        return self._request("GET", "/api/v3/release", query={"movieId": movie_id})

    def get_queue(self) -> list[dict[str, Any]]:
        payload = self._request(
            "GET",
            "/api/v3/queue",
            query={
                "page": 1,
                "pageSize": 200,
                "sortKey": "timeleft",
                "sortDirection": "descending",
            },
        )
        return payload.get("records", [])

    def post_command(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        return self._request("POST", "/api/v3/command", payload=payload)

    def search_movie(self, movie_id: int) -> dict[str, Any] | None:
        failures: list[str] = []
        for template in SEARCH_COMMAND_ATTEMPTS:
            payload = {}
            for key, value in template.items():
                if value == "__IDS__":
                    payload[key] = [movie_id]
                elif value == "__ID__":
                    payload[key] = movie_id
                else:
                    payload[key] = value
            try:
                return self.post_command(payload)
            except ApiError as exc:
                failures.append(f"{payload['name']} -> {exc.status}")
        joined = ", ".join(failures) if failures else "no attempts made"
        raise RuntimeError(f"Unable to trigger movie search for {movie_id}: {joined}")


@dataclass(frozen=True)
class FileMeta:
    languages: tuple[str, ...]
    quality_name: str
    source_id: int | None
    resolution: int | None
    relative_path: str


@dataclass(frozen=True)
class Candidate:
    movie_id: int
    title: str
    year: int | None
    current: FileMeta
    current_score: int
    last_grabbed_at: datetime | None
    reasons: tuple[str, ...]
    best_hungarian_release: dict[str, Any] | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Guard Radarr against recent bad language swaps.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--apply", action="store_true", help="Trigger Radarr movie searches."
    )
    parser.add_argument(
        "--base-url", default="http://127.0.0.1:7878", help="Radarr base URL."
    )
    parser.add_argument(
        "--config-path",
        default="/srv/appdata/radarr/config.xml",
        help="Local or remote path to Radarr config.xml.",
    )
    parser.add_argument("--api-key", default="", help="Override the Radarr API key.")
    parser.add_argument(
        "--ssh-host", default="", help="SSH host used to read remote config.xml."
    )
    parser.add_argument(
        "--ssh-user", default="", help="SSH user for remote config.xml reads."
    )
    parser.add_argument("--ssh-key", default="", help="SSH private key path.")
    parser.add_argument(
        "--recent-hours",
        type=int,
        default=72,
        help="Inspect movies touched in history during this window.",
    )
    parser.add_argument(
        "--search-cooldown-hours",
        type=int,
        default=24,
        help="Skip movies that were already grabbed recently.",
    )
    parser.add_argument(
        "--history-page-size",
        type=int,
        default=1000,
        help="Number of history records to inspect.",
    )
    parser.add_argument(
        "--history-max-pages",
        type=int,
        default=10,
        help="Maximum Radarr history pages to read.",
    )
    parser.add_argument(
        "--max-candidates",
        type=int,
        default=20,
        help="Maximum movies to search per run.",
    )
    parser.add_argument(
        "--movie-id",
        type=int,
        action="append",
        default=[],
        help="Restrict the run to one or more specific movie IDs.",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Optional JSON output file for the run summary.",
    )
    parser.add_argument(
        "--inspect-releases",
        action="store_true",
        help="Fetch interactive search results for each candidate. Slower, useful for verification.",
    )
    parser.add_argument(
        "--inspect-limit",
        type=int,
        default=0,
        help="How many preliminary candidates to verify with interactive search when --inspect-releases is set.",
    )
    return parser.parse_args()


def load_api_key(config_path: Path, cli_api_key: str, args: argparse.Namespace) -> str:
    if cli_api_key:
        return cli_api_key
    if config_path.exists():
        return parse_api_key(config_path.read_text(encoding="utf-8"))
    if args.ssh_host:
        xml_text = read_remote_file_via_ssh(args, config_path)
        return parse_api_key(xml_text)
    raise RuntimeError(
        f"Unable to read {config_path}. Pass --api-key or provide --ssh-host/--ssh-user."
    )


def parse_api_key(xml_text: str) -> str:
    root = ET.fromstring(xml_text)
    api_key = root.findtext("ApiKey", default="").strip()
    if not api_key:
        raise RuntimeError("No ApiKey found in config.xml")
    return api_key


def read_remote_file_via_ssh(args: argparse.Namespace, path: Path) -> str:
    if not args.ssh_user:
        raise RuntimeError("--ssh-user is required when --ssh-host is set")
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    if args.ssh_key:
        command.extend(["-i", args.ssh_key])
    command.append(f"{args.ssh_user}@{args.ssh_host}")
    command.append(f"cat {sh_quote(str(path))}")
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"Failed to read {path} over SSH: {completed.stderr.strip() or completed.stdout.strip()}"
        )
    return completed.stdout


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def quality_to_source_id(quality: dict[str, Any] | None) -> int | None:
    if not quality:
        return None
    source_name = (
        (((quality.get("quality") or {}).get("source")) or quality.get("source") or "")
        .strip()
        .lower()
    )
    if source_name:
        return SOURCE_NAME_TO_ID.get(source_name)

    quality_name = (
        ((quality.get("quality") or {}).get("name")) or quality.get("name") or ""
    ).lower()
    if "webdl" in quality_name:
        return SOURCE_NAME_TO_ID["webdl"]
    if "webrip" in quality_name:
        return SOURCE_NAME_TO_ID["webrip"]
    if "bluray" in quality_name:
        return SOURCE_NAME_TO_ID["bluray"]
    if quality_name.startswith("dvd"):
        return SOURCE_NAME_TO_ID["dvd"]
    if quality_name.startswith("hdtv") or quality_name == "raw-hd":
        return SOURCE_NAME_TO_ID["tv"]
    return None


def quality_to_resolution(quality: dict[str, Any] | None) -> int | None:
    if not quality:
        return None
    resolution = ((quality.get("quality") or {}).get("resolution")) or quality.get(
        "resolution"
    )
    if isinstance(resolution, int) and resolution > 0:
        return resolution
    quality_name = (
        ((quality.get("quality") or {}).get("name")) or quality.get("name") or ""
    )
    for token in ("2160", "1080", "720", "576", "480"):
        if token in quality_name:
            return int(token)
    return None


def movie_file_meta(movie_payload: dict[str, Any]) -> FileMeta | None:
    movie_file = movie_payload.get("movieFile") or {}
    quality = movie_file.get("quality") or {}
    quality_name = ((quality.get("quality") or {}).get("name")) or ""
    if not quality_name:
        return None
    return FileMeta(
        languages=tuple(
            lang.get("name")
            for lang in movie_file.get("languages", [])
            if lang.get("name")
        ),
        quality_name=quality_name,
        source_id=quality_to_source_id(quality),
        resolution=quality_to_resolution(quality),
        relative_path=movie_file.get("relativePath") or "",
    )


def matches_custom_format(custom_format: dict[str, Any], current: FileMeta) -> bool:
    specifications = custom_format.get("specifications", [])
    if not specifications:
        return False
    return all(matches_spec(spec, current) for spec in specifications)


def matches_spec(spec: dict[str, Any], current: FileMeta) -> bool:
    implementation = spec.get("implementation")
    fields = {field.get("name"): field.get("value") for field in spec.get("fields", [])}

    if implementation == "LanguageSpecification":
        wanted = fields.get("value")
        except_language = bool(fields.get("exceptLanguage"))
        language_name = (
            language_option_name(int(wanted)) if isinstance(wanted, int) else ""
        )
        if not language_name:
            return False
        has_language = language_name in current.languages
        if except_language:
            return any(lang != language_name for lang in current.languages)
        return has_language

    if implementation == "SourceSpecification":
        wanted = fields.get("value")
        return isinstance(wanted, int) and current.source_id == int(wanted)

    if implementation == "ResolutionSpecification":
        wanted = fields.get("value")
        return isinstance(wanted, int) and current.resolution == int(wanted)

    return False


def language_option_name(option_id: int) -> str:
    mapping = {
        1: "English",
        22: "Hungarian",
    }
    return mapping.get(option_id, "")


def current_custom_format_score(
    current: FileMeta,
    profile: dict[str, Any],
    custom_formats: dict[int, dict[str, Any]],
) -> int:
    total = 0
    for item in profile.get("formatItems", []):
        format_id = item.get("format")
        if not isinstance(format_id, int):
            continue
        custom_format = custom_formats.get(format_id)
        if custom_format and matches_custom_format(custom_format, current):
            total += int(item.get("score", 0))
    return total


def current_language_class(current: FileMeta) -> str:
    languages = set(current.languages)
    if "Hungarian" in languages:
        return "hungarian_present"
    if "English" in languages:
        return "english_only"
    return "foreign_or_unknown"


def best_approved_hungarian_release(
    releases: list[dict[str, Any]],
) -> dict[str, Any] | None:
    approved = [
        release
        for release in releases
        if release.get("approved")
        and any(
            lang.get("name") == "Hungarian" for lang in release.get("languages", [])
        )
    ]
    if not approved:
        return None
    approved.sort(
        key=lambda release: (
            int(release.get("customFormatScore", 0)),
            (((release.get("quality") or {}).get("quality") or {}).get("name")) or "",
        ),
        reverse=True,
    )
    return approved[0]


def compact_release(release: dict[str, Any]) -> dict[str, Any]:
    return {
        "title": release.get("title"),
        "quality": (((release.get("quality") or {}).get("quality") or {}).get("name")),
        "languages": [lang.get("name") for lang in release.get("languages", [])],
        "customFormats": [fmt.get("name") for fmt in release.get("customFormats", [])],
        "customFormatScore": int(release.get("customFormatScore", 0)),
        "indexer": release.get("indexer"),
    }


def build_recent_history_maps(
    history: list[dict[str, Any]],
    *,
    since: datetime,
) -> tuple[
    dict[int, list[dict[str, Any]]],
    dict[int, list[dict[str, Any]]],
    dict[int, datetime],
]:
    imports_by_movie: dict[int, list[dict[str, Any]]] = {}
    deletes_by_movie: dict[int, list[dict[str, Any]]] = {}
    last_grabbed_at: dict[int, datetime] = {}

    for record in history:
        when = parse_datetime(record.get("date"))
        if when is None or when < since:
            continue
        movie_id = record.get("movieId")
        if not isinstance(movie_id, int):
            continue
        event_type = record.get("eventType")
        if event_type in SUSPICIOUS_IMPORT_EVENTS:
            imports_by_movie.setdefault(movie_id, []).append(record)
        elif (
            event_type in DELETE_EVENTS
            and (record.get("data") or {}).get("reason") == "Upgrade"
        ):
            deletes_by_movie.setdefault(movie_id, []).append(record)
        elif event_type == "grabbed":
            last = last_grabbed_at.get(movie_id)
            if last is None or when > last:
                last_grabbed_at[movie_id] = when
    return imports_by_movie, deletes_by_movie, last_grabbed_at


def history_languages(record: dict[str, Any]) -> tuple[str, ...]:
    return tuple(
        lang.get("name") for lang in record.get("languages", []) if lang.get("name")
    )


def reasons_for_candidate(
    movie_id: int,
    current: FileMeta,
    imports_by_movie: dict[int, list[dict[str, Any]]],
    deletes_by_movie: dict[int, list[dict[str, Any]]],
) -> list[str]:
    reasons: list[str] = []
    current_class = current_language_class(current)
    for record in imports_by_movie.get(movie_id, []):
        imported_languages = set(history_languages(record))
        if not imported_languages:
            reasons.append("recent import with unknown languages")
        elif (
            "Hungarian" not in imported_languages
            and "English" not in imported_languages
        ):
            reasons.append(
                f"recent import language outside target set: {', '.join(sorted(imported_languages))}"
            )
        elif current_class != "hungarian_present":
            reasons.append(
                f"recent import currently lacks Hungarian: {', '.join(sorted(imported_languages))}"
            )
    for record in deletes_by_movie.get(movie_id, []):
        deleted_languages = set(history_languages(record))
        if "Hungarian" in deleted_languages and current_class != "hungarian_present":
            reasons.append("recent upgrade deleted a Hungarian file")
    deduped: list[str] = []
    seen: set[str] = set()
    for reason in reasons:
        if reason not in seen:
            deduped.append(reason)
            seen.add(reason)
    return deduped


def build_candidates(
    client: RadarrClient,
    movies: list[dict[str, Any]],
    profile: dict[str, Any],
    custom_formats: dict[int, dict[str, Any]],
    args: argparse.Namespace,
) -> list[Candidate]:
    since = datetime.now(UTC) - timedelta(hours=args.recent_hours)
    history = client.get_history_since(
        since=since,
        page_size=args.history_page_size,
        max_pages=args.history_max_pages,
    )
    imports_by_movie, deletes_by_movie, last_grabbed_at = build_recent_history_maps(
        history, since=since
    )

    candidate_movies = [movie for movie in movies if isinstance(movie.get("id"), int)]
    if args.movie_id:
        wanted_ids = set(args.movie_id)
        candidate_movies = [
            movie for movie in candidate_movies if movie["id"] in wanted_ids
        ]
    else:
        touched_ids = set(imports_by_movie) | set(deletes_by_movie)
        candidate_movies = [
            movie for movie in candidate_movies if movie["id"] in touched_ids
        ]

    preliminary: list[Candidate] = []

    for movie in candidate_movies:
        current = movie_file_meta(movie)
        if current is None:
            continue
        if current_language_class(current) == "hungarian_present":
            continue
        reasons = reasons_for_candidate(
            movie["id"], current, imports_by_movie, deletes_by_movie
        )
        if not reasons:
            continue
        current_score = current_custom_format_score(current, profile, custom_formats)
        preliminary.append(
            Candidate(
                movie_id=movie["id"],
                title=movie.get("title", ""),
                year=movie.get("year"),
                current=current,
                current_score=current_score,
                last_grabbed_at=last_grabbed_at.get(movie["id"]),
                reasons=tuple(reasons),
                best_hungarian_release=None,
            )
        )

    preliminary.sort(key=candidate_priority, reverse=True)
    if not args.inspect_releases:
        return preliminary

    min_improvement = int(profile.get("minUpgradeFormatScore", 0))
    inspect_limit = args.inspect_limit or max(
        args.max_candidates * 3, args.max_candidates
    )
    verified: list[Candidate] = []
    for candidate in preliminary[:inspect_limit]:
        releases = client.get_releases(candidate.movie_id)
        best_release = best_approved_hungarian_release(releases)
        if best_release is None:
            continue
        best_score = int(best_release.get("customFormatScore", 0))
        if best_score < candidate.current_score + min_improvement:
            continue
        verified.append(
            Candidate(
                movie_id=candidate.movie_id,
                title=candidate.title,
                year=candidate.year,
                current=candidate.current,
                current_score=candidate.current_score,
                last_grabbed_at=candidate.last_grabbed_at,
                reasons=candidate.reasons,
                best_hungarian_release=compact_release(best_release),
            )
        )
    verified.sort(key=candidate_priority, reverse=True)
    return verified


def candidate_priority(candidate: Candidate) -> tuple[int, float, int]:
    deleted_hungarian = any(
        "deleted a Hungarian file" in reason for reason in candidate.reasons
    )
    current_class = current_language_class(candidate.current)
    severity = 0
    if deleted_hungarian:
        severity += 4
    if current_class == "foreign_or_unknown":
        severity += 2
    elif current_class == "english_only":
        severity += 1
    last_grabbed = (
        candidate.last_grabbed_at.timestamp() if candidate.last_grabbed_at else 0.0
    )
    return (severity, last_grabbed, 1000 - candidate.current_score)


def summarize_candidate(
    candidate: Candidate, cooldown_cutoff: datetime
) -> dict[str, Any]:
    last_grabbed = (
        candidate.last_grabbed_at.isoformat() if candidate.last_grabbed_at else None
    )
    cooldown_active = bool(
        candidate.last_grabbed_at and candidate.last_grabbed_at >= cooldown_cutoff
    )
    return {
        "movieId": candidate.movie_id,
        "movie": f"{candidate.title} ({candidate.year})"
        if candidate.year
        else candidate.title,
        "reasons": list(candidate.reasons),
        "current": {
            "quality": candidate.current.quality_name,
            "languages": list(candidate.current.languages),
            "relativePath": candidate.current.relative_path,
            "score": candidate.current_score,
        },
        "bestHungarianRelease": candidate.best_hungarian_release,
        "lastGrabbedAt": last_grabbed,
        "cooldownActive": cooldown_active,
    }


def main() -> int:
    args = parse_args()
    config_path = Path(args.config_path).expanduser()
    api_key = load_api_key(config_path, args.api_key, args)
    client = RadarrClient(args.base_url, api_key)

    movies = client.get_movies()
    if args.movie_id:
        wanted_ids = set(args.movie_id)
        movies = [movie for movie in movies if movie.get("id") in wanted_ids]

    if not movies:
        raise RuntimeError("No matching movies found")

    profile = client.get_quality_profile(
        next(
            int(movie.get("qualityProfileId"))
            for movie in movies
            if isinstance(movie.get("qualityProfileId"), int)
        )
    )
    custom_formats = {
        fmt["id"]: fmt
        for fmt in client.get_custom_formats()
        if isinstance(fmt.get("id"), int)
    }
    queue_records = client.get_queue()
    queued_movie_ids = {
        movie_id
        for record in queue_records
        for movie_id in [record.get("movieId")]
        if isinstance(movie_id, int)
    }

    candidates = build_candidates(client, movies, profile, custom_formats, args)
    cooldown_cutoff = datetime.now(UTC) - timedelta(hours=args.search_cooldown_hours)

    actionable: list[Candidate] = []
    skipped_queue: list[Candidate] = []
    skipped_cooldown: list[Candidate] = []
    for candidate in candidates:
        if candidate.movie_id in queued_movie_ids:
            skipped_queue.append(candidate)
        elif (
            candidate.best_hungarian_release is None
            and candidate.last_grabbed_at
            and candidate.last_grabbed_at >= cooldown_cutoff
        ):
            skipped_cooldown.append(candidate)
        else:
            actionable.append(candidate)

    actionable = actionable[: args.max_candidates]

    actions: list[dict[str, Any]] = []
    if args.apply:
        for candidate in actionable:
            command = client.search_movie(candidate.movie_id)
            actions.append(
                {
                    "movieId": candidate.movie_id,
                    "movie": f"{candidate.title} ({candidate.year})"
                    if candidate.year
                    else candidate.title,
                    "action": "search_triggered",
                    "command": command,
                }
            )

    summary = {
        "timestampUtc": datetime.now(UTC).isoformat(),
        "apply": args.apply,
        "baseUrl": args.base_url,
        "recentHours": args.recent_hours,
        "searchCooldownHours": args.search_cooldown_hours,
        "candidateCount": len(candidates),
        "actionableCount": len(actionable),
        "skippedQueueCount": len(skipped_queue),
        "skippedCooldownCount": len(skipped_cooldown),
        "actionable": [
            summarize_candidate(candidate, cooldown_cutoff) for candidate in actionable
        ],
        "skippedQueue": [
            summarize_candidate(candidate, cooldown_cutoff)
            for candidate in skipped_queue
        ],
        "skippedCooldown": [
            summarize_candidate(candidate, cooldown_cutoff)
            for candidate in skipped_cooldown
        ],
        "actions": actions,
    }

    text = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.output_json:
        output_path = Path(args.output_json).expanduser()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
