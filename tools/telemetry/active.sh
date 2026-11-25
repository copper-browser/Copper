#!/bin/sh
# Copper's active users from the anonymous daily ping (Sources/Search/Fork/Ping.swift,
# infra/site-aws.yml PingTable). Needs Exowatt AWS credentials (aws sso login).
#   tools/telemetry/active.sh [DAYS]   # default 14
# Per day: DAU (d) and installs (new). Then WAU = this ISO week's w, MAU = this month's m.
set -eu
aws dynamodb scan --region us-east-1 --table-name copper-pings --output json |
DAYS="${1:-14}" python3 -c '
import datetime as dt, json, os, sys
rows = {i["day"]["S"]: {k: int(v["N"]) for k, v in i.items() if "N" in v} for i in json.load(sys.stdin)["Items"]}
get = lambda day, k: rows.get(day.isoformat(), {}).get(k, 0)
today = dt.datetime.now(dt.timezone.utc).date()
print("day         DAU  new")
for n in range(int(os.environ["DAYS"]) - 1, -1, -1):
    day = today - dt.timedelta(n)
    print("%s  %4d %4d" % (day, get(day, "d"), get(day, "new")))
monday = today - dt.timedelta(today.weekday())
week = [monday + dt.timedelta(n) for n in range((today - monday).days + 1)]
month = [today.replace(day=n) for n in range(1, today.day + 1)]
print("WAU (week of %s): %d" % (monday, sum(get(d, "w") for d in week)))
print("MAU (%s): %d" % (today.strftime("%Y-%m"), sum(get(d, "m") for d in month)))
print("installs, all time: %d" % sum(r.get("new", 0) for r in rows.values()))
'
