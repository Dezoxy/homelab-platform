#!/usr/bin/env python3
"""Backfill existing Radarr movies with Hungarian releases in a controlled pass.

This is intentionally separate from the recent-swap guard. The backfill script:

- walks the existing library for movies that currently do not contain Hungarian audio
- respects Radarr queue capacity so it does not flood downloads
- verifies that an approved Hungarian release is currently visible before searching
- records a one-pass decision for each title so repeated runs eventually finish

Once the pass is complete, Radarr's normal profile scoring should handle future releases.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

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
TERMINAL_STATUSES = {"complete", "no_candidate"}
IN_FLIGHT_STATUSES = {"queued", "searched", "download_client"}
INCOMPLETE_QBITTORRENT_STATES = {
    "allocating",
    "checkingDL",
    "checkingResumeData",
    "downloading",
    "error",
    "forcedDL",
    "metaDL",
    "missingFiles",
    "moving",
    "pausedDL",
    "queuedDL",
    "stalledDL",
    "unknown",
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

    def get_quality_profile(self, profile_id: int) -> dict[str, Any]:
        return self._request("GET", f"/api/v3/qualityprofile/{profile_id}")

    def get_custom_formats(self) -> list[dict[str, Any]]:
        return self._request("GET", "/api/v3/customformat")

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


class QbittorrentClient:
    """Small qBittorrent Web API client used only for queue pressure checks."""

    def __init__(self, base_url: str, username: str, password: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def login(self) -> None:
        if not self.username and not self.password:
            return
        payload = urllib.parse.urlencode(
            {"username": self.username, "password": self.password}
        ).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}/api/v2/auth/login",
            method="POST",
            data=payload,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with self.opener.open(request, timeout=30) as response:
            body = response.read().decode("utf-8", errors="replace").strip()
        if body != "Ok.":
            raise RuntimeError("qBittorrent authentication failed")

    def get_torrents(self, category: str = "") -> list[dict[str, Any]]:
        query: dict[str, Any] = {}
        if category:
            query["category"] = category
        url = f"{self.base_url}/api/v2/torrents/info"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        with self.opener.open(url, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))


@dataclass(frozen=True)
class FileMeta:
    languages: tuple[str, ...]
    quality_name: str
    source_id: int | None
    resolution: int | None
    relative_path: str


@dataclass(frozen=True)
class BackfillMovie:
    movie_id: int
    title: str
    year: int | None
    monitored: bool
    original_language: str
    release_age_days: int
    current: FileMeta
    current_score: int


@dataclass(frozen=True)
class Candidate:
    movie: BackfillMovie
    best_hungarian_release: dict[str, Any]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Backfill the Radarr library with Hungarian releases in small verified batches.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Trigger Radarr searches and persist pass state.",
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
        "--state-file",
        default="out/radarr-hungarian-backfill/state.json",
        help="Persistent one-pass state file.",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Optional JSON output file for the current run summary.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=10,
        help="Maximum verified movie searches to trigger in one run.",
    )
    parser.add_argument(
        "--max-active-queue",
        type=int,
        default=10,
        help=(
            "Do not add new searches when the effective active queue is already at or above this "
            "count. If qBittorrent is configured, the effective count is max(Radarr queue, "
            "qBittorrent active torrents)."
        ),
    )
    parser.add_argument(
        "--search-cooldown-hours",
        type=int,
        default=24,
        help="Do not search the same movie again within this many hours.",
    )
    parser.add_argument(
        "--allow-download-client-mismatch",
        action="store_true",
        help=(
            "Continue searching even when qBittorrent has more active torrents than Radarr "
            "has queue records. By default the script pauses in this state."
        ),
    )
    parser.add_argument(
        "--qbittorrent-url",
        default=os.environ.get("QBITTORRENT_URL", ""),
        help="Optional qBittorrent Web UI URL used for direct active torrent counting.",
    )
    parser.add_argument(
        "--qbittorrent-username",
        default=os.environ.get("QBITTORRENT_USERNAME", ""),
        help="qBittorrent username. Defaults to QBITTORRENT_USERNAME.",
    )
    parser.add_argument(
        "--qbittorrent-password",
        default=os.environ.get("QBITTORRENT_PASSWORD", ""),
        help="qBittorrent password. Defaults to QBITTORRENT_PASSWORD.",
    )
    parser.add_argument(
        "--qbittorrent-category",
        default=os.environ.get("QBITTORRENT_CATEGORY", ""),
        help="Optional qBittorrent category filter, for example radarr.",
    )
    parser.add_argument(
        "--qbittorrent-count-mode",
        choices=("incomplete", "all"),
        default=os.environ.get("QBITTORRENT_COUNT_MODE", "incomplete"),
        help="Which qBittorrent torrents count against max-active-queue.",
    )
    parser.add_argument(
        "--inspect-limit",
        type=int,
        default=0,
        help="Maximum pending titles to verify in one run. Defaults to batch-size * 4.",
    )
    parser.add_argument(
        "--include-unmonitored",
        action="store_true",
        help="Include unmonitored movies in the backfill pass.",
    )
    parser.add_argument(
        "--reset-state",
        action="store_true",
        help="Discard the existing one-pass state and start a fresh pass.",
    )
    parser.add_argument(
        "--movie-id",
        type=int,
        action="append",
        default=[],
        help="Restrict the run to one or more specific movie IDs.",
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


def timestamp_utc() -> str:
    return datetime.now(UTC).isoformat()


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def normalize_release_title(value: str | None) -> str:
    if not value:
        return ""
    return re.sub(r"[^a-z0-9]+", "", value.lower())


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


def language_option_name(option_id: int) -> str:
    mapping = {
        1: "English",
        22: "Hungarian",
    }
    return mapping.get(option_id, "")


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


def matches_custom_format(custom_format: dict[str, Any], current: FileMeta) -> bool:
    specifications = custom_format.get("specifications", [])
    if not specifications:
        return False
    return all(matches_spec(spec, current) for spec in specifications)


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


def qbittorrent_queue_snapshot(args: argparse.Namespace) -> dict[str, Any] | None:
    if not args.qbittorrent_url:
        return None

    client = QbittorrentClient(
        args.qbittorrent_url,
        args.qbittorrent_username,
        args.qbittorrent_password,
    )
    client.login()
    torrents = client.get_torrents(args.qbittorrent_category)
    active = [
        torrent
        for torrent in torrents
        if args.qbittorrent_count_mode == "all"
        or torrent.get("state") in INCOMPLETE_QBITTORRENT_STATES
        or float(torrent.get("progress", 0) or 0) < 1.0
    ]
    states: dict[str, int] = {}
    for torrent in active:
        state = str(torrent.get("state") or "unknown")
        states[state] = states.get(state, 0) + 1
    return {
        "url": args.qbittorrent_url,
        "category": args.qbittorrent_category or None,
        "countMode": args.qbittorrent_count_mode,
        "totalCount": len(torrents),
        "activeCount": len(active),
        "activeStates": dict(sorted(states.items())),
        "_torrentNames": [str(torrent.get("name") or "") for torrent in torrents],
        "_activeTorrentNames": [str(torrent.get("name") or "") for torrent in active],
        "sample": [
            {
                "name": torrent.get("name"),
                "state": torrent.get("state"),
                "progress": torrent.get("progress"),
                "category": torrent.get("category"),
            }
            for torrent in active[:20]
        ],
    }


def public_qbittorrent_snapshot(
    snapshot: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if snapshot is None:
        return None
    return {key: value for key, value in snapshot.items() if not key.startswith("_")}


def searched_recently(entry: dict[str, Any], cutoff: datetime) -> bool:
    searched_at = parse_datetime(entry.get("lastSearchTriggeredAt"))
    return searched_at is not None and searched_at >= cutoff


def load_state(path: Path, reset: bool) -> dict[str, Any]:
    if reset or not path.exists():
        return {
            "version": 1,
            "createdAt": timestamp_utc(),
            "updatedAt": timestamp_utc(),
            "movies": {},
        }
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(path: Path, state: dict[str, Any]) -> None:
    state["updatedAt"] = timestamp_utc()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def ensure_entry(state: dict[str, Any], movie: BackfillMovie) -> dict[str, Any]:
    movie_key = str(movie.movie_id)
    movies = state.setdefault("movies", {})
    entry = movies.setdefault(movie_key, {})
    entry["movieId"] = movie.movie_id
    entry["title"] = movie.title
    entry["year"] = movie.year
    return entry


def set_entry_status(entry: dict[str, Any], status: str, **extra: Any) -> None:
    entry["status"] = status
    entry["updatedAt"] = timestamp_utc()
    for key, value in extra.items():
        entry[key] = value


def build_backlog_movies(
    movies: list[dict[str, Any]],
    profile: dict[str, Any],
    custom_formats: dict[int, dict[str, Any]],
    include_unmonitored: bool,
    wanted_ids: set[int],
) -> tuple[list[BackfillMovie], set[int]]:
    backlog: list[BackfillMovie] = []
    hungarian_present_ids: set[int] = set()
    now = datetime.now(UTC)

    for movie in movies:
        movie_id = movie.get("id")
        if not isinstance(movie_id, int):
            continue
        if wanted_ids and movie_id not in wanted_ids:
            continue
        current = movie_file_meta(movie)
        if current is None:
            continue
        if current_language_class(current) == "hungarian_present":
            hungarian_present_ids.add(movie_id)
            continue
        monitored = bool(movie.get("monitored"))
        if not include_unmonitored and not monitored:
            continue
        release_at = (
            parse_datetime(movie.get("physicalRelease"))
            or parse_datetime(movie.get("digitalRelease"))
            or parse_datetime(movie.get("releaseDate"))
            or parse_datetime(movie.get("added"))
        )
        release_age_days = 0
        if release_at is not None:
            release_age_days = max(0, int((now - release_at).total_seconds() // 86400))
        backlog.append(
            BackfillMovie(
                movie_id=movie_id,
                title=movie.get("title", ""),
                year=movie.get("year"),
                monitored=monitored,
                original_language=((movie.get("originalLanguage") or {}).get("name"))
                or "",
                release_age_days=release_age_days,
                current=current,
                current_score=current_custom_format_score(
                    current, profile, custom_formats
                ),
            )
        )
    return backlog, hungarian_present_ids


def backlog_priority(movie: BackfillMovie) -> tuple[int, int, int, int, int, str]:
    foreign_current = (
        1 if current_language_class(movie.current) == "foreign_or_unknown" else 0
    )
    english_original = 1 if movie.original_language == "English" else 0
    english_current = (
        1 if current_language_class(movie.current) == "english_only" else 0
    )
    lower_score_priority = 1000 - movie.current_score
    return (
        foreign_current,
        english_original,
        english_current,
        movie.release_age_days,
        lower_score_priority,
        movie.title.lower(),
    )


def movie_snapshot(movie: BackfillMovie) -> dict[str, Any]:
    return {
        "movieId": movie.movie_id,
        "movie": f"{movie.title} ({movie.year})" if movie.year else movie.title,
        "current": {
            "quality": movie.current.quality_name,
            "languages": list(movie.current.languages),
            "relativePath": movie.current.relative_path,
            "score": movie.current_score,
        },
    }


def main() -> int:
    args = parse_args()
    config_path = Path(args.config_path).expanduser()
    state_path = Path(args.state_file).expanduser()
    api_key = load_api_key(config_path, args.api_key, args)
    client = RadarrClient(args.base_url, api_key)

    state = load_state(state_path, args.reset_state)
    wanted_ids = set(args.movie_id)

    movies = client.get_movies()
    if wanted_ids:
        movies = [movie for movie in movies if movie.get("id") in wanted_ids]
    if not movies:
        raise RuntimeError("No matching movies found")

    profile = client.get_quality_profile(
        next(
            profile_id
            for movie in movies
            for profile_id in [movie.get("qualityProfileId")]
            if isinstance(profile_id, int)
        )
    )
    custom_formats = {
        fmt["id"]: fmt
        for fmt in client.get_custom_formats()
        if isinstance(fmt.get("id"), int)
    }
    queue_records = client.get_queue()
    qbittorrent_snapshot = qbittorrent_queue_snapshot(args)
    download_client_titles = {
        normalize_release_title(name)
        for name in (qbittorrent_snapshot or {}).get("_torrentNames", [])
        if normalize_release_title(name)
    }
    queue_movie_ids = {
        movie_id
        for record in queue_records
        for movie_id in [record.get("movieId")]
        if isinstance(movie_id, int)
    }

    backlog, hungarian_present_ids = build_backlog_movies(
        movies,
        profile,
        custom_formats,
        args.include_unmonitored,
        wanted_ids,
    )
    backlog_by_id = {movie.movie_id: movie for movie in backlog}
    search_cooldown_cutoff = datetime.now(UTC) - timedelta(
        hours=args.search_cooldown_hours
    )

    if args.apply:
        for movie_id in hungarian_present_ids:
            entry = state["movies"].get(str(movie_id))
            if entry is not None:
                set_entry_status(entry, "complete")

    for movie in backlog:
        entry = ensure_entry(state, movie)
        entry["current"] = movie_snapshot(movie)["current"]
        if args.apply:
            status = entry.get("status")
            if movie.movie_id in queue_movie_ids:
                set_entry_status(entry, "queued")
            elif status == "searched" and searched_recently(
                entry, search_cooldown_cutoff
            ):
                entry["current"] = movie_snapshot(movie)["current"]
            elif status in IN_FLIGHT_STATUSES or status not in TERMINAL_STATUSES:
                set_entry_status(entry, "pending")

    queue_backlog_ids = {
        movie_id for movie_id in queue_movie_ids if movie_id in backlog_by_id
    }

    pending_movies: list[BackfillMovie] = []
    no_candidate_ids: set[int] = set()
    complete_ids: set[int] = set(hungarian_present_ids)
    for movie in backlog:
        entry = state["movies"].get(str(movie.movie_id), {})
        status = entry.get("status")
        if status == "no_candidate":
            no_candidate_ids.add(movie.movie_id)
        elif status == "complete":
            complete_ids.add(movie.movie_id)
        elif status == "searched" and searched_recently(entry, search_cooldown_cutoff):
            continue
        elif movie.movie_id not in queue_backlog_ids:
            pending_movies.append(movie)

    pending_movies.sort(key=backlog_priority, reverse=True)

    radarr_queue_count = len(queue_records)
    qbittorrent_active_count = (
        int(qbittorrent_snapshot["activeCount"])
        if qbittorrent_snapshot is not None
        else 0
    )
    effective_queue_count = max(radarr_queue_count, qbittorrent_active_count)
    download_client_mismatch = (
        qbittorrent_snapshot is not None
        and qbittorrent_active_count > radarr_queue_count
        and not args.allow_download_client_mismatch
    )
    available_slots = max(0, args.max_active_queue - effective_queue_count)
    search_slots = min(args.batch_size, available_slots)

    inspected_limit = args.inspect_limit or max(args.batch_size * 4, args.batch_size)
    inspected: list[dict[str, Any]] = []
    no_candidate_this_run: list[dict[str, Any]] = []
    actionable: list[Candidate] = []
    download_client_existing: list[dict[str, Any]] = []
    queue_busy = search_slots <= 0 or download_client_mismatch

    if not queue_busy:
        min_improvement = int(profile.get("minUpgradeFormatScore", 0))
        for movie in pending_movies[:inspected_limit]:
            releases = client.get_releases(movie.movie_id)
            best_release = best_approved_hungarian_release(releases)
            if best_release is None:
                inspected.append(movie_snapshot(movie))
                no_candidate_this_run.append(movie_snapshot(movie))
                if args.apply:
                    entry = ensure_entry(state, movie)
                    set_entry_status(
                        entry, "no_candidate", lastCheckedAt=timestamp_utc()
                    )
                continue
            best_score = int(best_release.get("customFormatScore", 0))
            if best_score < movie.current_score + min_improvement:
                inspected.append(movie_snapshot(movie))
                no_candidate_this_run.append(movie_snapshot(movie))
                if args.apply:
                    entry = ensure_entry(state, movie)
                    set_entry_status(
                        entry,
                        "no_candidate",
                        lastCheckedAt=timestamp_utc(),
                        bestHungarianRelease=compact_release(best_release),
                    )
                continue
            release_title = normalize_release_title(best_release.get("title"))
            if release_title and release_title in download_client_titles:
                snapshot = movie_snapshot(movie)
                snapshot["bestHungarianRelease"] = compact_release(best_release)
                inspected.append(snapshot)
                download_client_existing.append(snapshot)
                if args.apply:
                    entry = ensure_entry(state, movie)
                    set_entry_status(
                        entry,
                        "download_client",
                        lastCheckedAt=timestamp_utc(),
                        bestHungarianRelease=compact_release(best_release),
                    )
                continue
            inspected.append(movie_snapshot(movie))
            actionable.append(
                Candidate(
                    movie=movie,
                    best_hungarian_release=compact_release(best_release),
                )
            )
            if len(actionable) >= search_slots:
                break

    actions: list[dict[str, Any]] = []
    if args.apply:
        for candidate in actionable:
            command = client.search_movie(candidate.movie.movie_id)
            entry = ensure_entry(state, candidate.movie)
            set_entry_status(
                entry,
                "searched",
                lastSearchTriggeredAt=timestamp_utc(),
                bestHungarianRelease=candidate.best_hungarian_release,
            )
            actions.append(
                {
                    "movieId": candidate.movie.movie_id,
                    "movie": f"{candidate.movie.title} ({candidate.movie.year})"
                    if candidate.movie.year
                    else candidate.movie.title,
                    "action": "search_triggered",
                    "bestHungarianRelease": candidate.best_hungarian_release,
                    "command": command,
                }
            )

    if args.apply:
        save_state(state_path, state)

    pending_count = 0
    queued_count = 0
    complete_count = 0
    no_candidate_count = 0
    searched_cooldown_count = 0
    download_client_count = 0
    for movie in backlog:
        entry = state["movies"].get(str(movie.movie_id), {})
        status = entry.get("status", "pending")
        if movie.movie_id in queue_backlog_ids:
            queued_count += 1
        elif status == "download_client":
            download_client_count += 1
        elif status == "searched" and searched_recently(entry, search_cooldown_cutoff):
            searched_cooldown_count += 1
        elif status == "complete":
            complete_count += 1
        elif status == "no_candidate":
            no_candidate_count += 1
        else:
            pending_count += 1

    backfill_completed = (
        pending_count == 0
        and queued_count == 0
        and download_client_count == 0
        and searched_cooldown_count == 0
    )
    summary = {
        "timestampUtc": timestamp_utc(),
        "apply": args.apply,
        "stateFile": str(state_path),
        "batchSize": args.batch_size,
        "maxActiveQueue": args.max_active_queue,
        "inspectLimit": inspected_limit,
        "queueBusy": queue_busy,
        "queueCount": effective_queue_count,
        "radarrQueueCount": radarr_queue_count,
        "qbittorrentActiveCount": qbittorrent_active_count,
        "downloadClientMismatch": download_client_mismatch,
        "qbittorrent": public_qbittorrent_snapshot(qbittorrent_snapshot),
        "queueBackfillCount": queued_count,
        "downloadClientBackfillCount": download_client_count,
        "searchedCooldownCount": searched_cooldown_count,
        "nonHungarianBacklogCount": len(backlog),
        "pendingCount": pending_count,
        "completeCount": complete_count,
        "noCandidateCount": no_candidate_count,
        "searchedThisRunCount": len(actions) if args.apply else len(actionable),
        "backfillCompleted": backfill_completed,
        "suggestedAutomationAction": "pause_or_delete"
        if backfill_completed
        else "keep_running",
        "inspected": inspected,
        "noCandidateThisRun": no_candidate_this_run,
        "downloadClientExisting": download_client_existing,
        "actionable": [
            {
                **movie_snapshot(candidate.movie),
                "bestHungarianRelease": candidate.best_hungarian_release,
            }
            for candidate in actionable
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
