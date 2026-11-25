# The daily ping

Copper's only telemetry, so we know how many people use it (Brave's usage-ping model, no lasting ID).

**What is sent.** At most once per UTC day, about ten seconds after launch (or at the next hourly
look if Copper stays open past midnight UTC), `Fork/Ping.swift` sends one GET:

    https://copper.exowatt.com/ping?v=1.0.20261125.90&os=15.1&chip=arm64&d=1[&w=1][&m=1][&new=1]

`v` is Copper's version, `os` the macOS major.minor, `chip` arm64 or x86_64. `w` / `m` mark the
first ping of this ISO week / calendar month, `new` the first ever. Nothing else: no ID, no
address, no cookies. The only thing kept on the Mac is the day of the last ping
(`ping.last` in Copper's defaults); a failed ping is tried again the next hour.

**What is kept.** CloudFront hands the query (no headers, no cookies) to a Lambda that adds 1 to
counters in the DynamoDB row for the day: `d`, `w`, `m`, `new`, and `v#…`, `os#…`, `chip#…`
(infra/site-aws.yml, `PingTable`). The IP is never stored or logged, and CloudFront access logs
are off. DAU is a day's `d`, WAU the sum of `w` over the ISO week, MAU the sum of `m` over the
month, installs the sum of `new`: `tools/telemetry/active.sh [DAYS]` prints them.

**When it is not sent.** Settings › Privacy › Usage › "Send an anonymous daily ping" off
(`defaults write com.collinrijock.copper ping -bool false` does the same). Never from a test or
probe world, a dev build, headless Copper or a bench run.
