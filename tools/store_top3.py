import argparse
import hashlib
import json
import sqlite3
from pathlib import Path


def connect(path):
    connection = sqlite3.connect(path)
    connection.execute(
        """CREATE TABLE IF NOT EXISTS recommendations (
        recommendation_date TEXT NOT NULL, code TEXT NOT NULL, name TEXT,
        rank INTEGER, recommendation_time TEXT, market TEXT, open_price REAL,
        previous_close REAL, recommendation_price REAL, virtual_entry_price REAL,
        target_price REAL, stop_price REAL, rise_probability REAL,
        probability_type TEXT, reasons TEXT, data_as_of TEXT,
        PRIMARY KEY (recommendation_date, code))"""
    )
    connection.execute(
        """CREATE TABLE IF NOT EXISTS performance (
        recommendation_date TEXT NOT NULL, code TEXT NOT NULL,
        d1_close REAL, d5_close REAL, d20_close REAL, d60_close REAL,
        d120_close REAL, highest_price REAL, lowest_price REAL,
        stop_reached INTEGER, target_reached INTEGER, maximum_rise REAL,
        maximum_decline REAL, current_price REAL, current_return REAL,
        market_excess_return REAL, updated_at TEXT,
        PRIMARY KEY (recommendation_date, code))"""
    )
    connection.execute(
        """CREATE TABLE IF NOT EXISTS audit_snapshots (
        kind TEXT NOT NULL, digest TEXT NOT NULL, recommendation_date TEXT NOT NULL,
        code TEXT NOT NULL, payload TEXT NOT NULL,
        stored_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
        PRIMARY KEY (kind, digest))"""
    )
    return connection


def store_snapshot(connection, kind, item):
    # Canonical full payload retains scores, factors, D+2/D+3 and model versions.
    payload = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    connection.execute(
        "INSERT OR IGNORE INTO audit_snapshots (kind, digest, recommendation_date, code, payload) VALUES (?, ?, ?, ?, ?)",
        (kind, digest, item["recommendationDate"], item["code"], payload),
    )


def store_recommendations(connection, payload):
    items = payload if isinstance(payload, list) else payload.get("top3", [])
    for item in items:
        store_snapshot(connection, "recommendation", item)
        connection.execute(
            """INSERT OR REPLACE INTO recommendations VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                item.get("recommendationDate"), item.get("code"), item.get("name"),
                item.get("rank"), item.get("recommendationTime"), item.get("market"),
                item.get("openPrice"), item.get("previousClose"),
                item.get("recommendationPrice"),
                item.get("virtualEntryPrice") or item.get("plannedEntryPrice"),
                item.get("targetPrice"), item.get("stopPrice"),
                item.get("riseProbability"), item.get("probabilityType"),
                json.dumps(item.get("reasons", []), ensure_ascii=False),
                item.get("dataAsOf"),
            ),
        )


def store_performance(connection, payload):
    updated_at = payload.get("generatedAt")
    for item in payload.get("items", []):
        store_snapshot(connection, "performance", {**item, "validationGeneratedAt": updated_at})
        connection.execute(
            """INSERT OR REPLACE INTO performance VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                item.get("recommendationDate"), item.get("code"),
                item.get("d1Close"), item.get("d5Close"), item.get("d20Close"),
                item.get("d60Close"), item.get("d120Close"),
                item.get("highestPrice"), item.get("lowestPrice"),
                int(bool(item.get("stopReached"))),
                int(bool(item.get("targetReached"))),
                item.get("maximumRise"), item.get("maximumDecline"),
                item.get("currentPrice"), item.get("currentReturn"),
                item.get("marketExcessReturn"), updated_at,
            ),
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("recommendations", "performance"))
    parser.add_argument("source")
    parser.add_argument("database")
    args = parser.parse_args()
    payload = json.loads(Path(args.source).read_text(encoding="utf-8-sig"))
    connection = connect(args.database)
    with connection:
        if args.mode == "recommendations":
            store_recommendations(connection, payload)
        else:
            store_performance(connection, payload)
    connection.close()


if __name__ == "__main__":
    main()
