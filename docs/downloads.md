# Downloads

A download used to announce itself once — "Downloading x", a line that rose
from the bottom for under two seconds — and then say nothing until "Saved x".
Now there is a small door for it, and only while there is something to say.

## The door

At the foot of the sidebar, left of the bookmark, or at the right end of the
tab strip when the tabs are across the top. **It is not there until a download
starts.** While anything is arriving the arrow sits inside a ring that fills
with the total progress of everything active; a download whose size is unknown
turns the ring into a slow dashed circle rather than a false percentage. When
the last one lands the ring completes, the glyph becomes a check for a moment,
and the door settles into a resting arrow with a small dot: something finished
that you have not looked at yet. A failure shows an exclamation in the ember
colour a hot tab uses. Hover for `2 downloads · 1.1 MB/s`.

Once shown, the door stays for the session in its resting state; **Clear** in
the popover puts it away.

## The popover

Click the door. What is still arriving is on top, then this session's finished
and failed downloads newest first, then the most recent files from earlier
sessions (the same list the ⌘⇧J panel keeps, `downloads.json`).

Each row: the file's icon, its name, and one line of figures with digits that
hold still — `5.7 of 10.5 MB · 588 KB/s · 8 s left`, or `12.6 MB · example.com`
once it has landed, or `Failed at 2.6 MB`. A 2 pt bar runs under an active row.

- **×** on an active row cancels it and removes the partial file.
- Click a finished row to open the file; hover for **Show in Finder** and a
  remove-from-list ×. Removing a row never deletes a file.
- **Retry** on a failed row resumes from where it stopped (WebKit's resume
  data) or starts over from the original request; the failed row is replaced.
- **Open Downloads Folder**, **Clear** (finished and failed rows go; active
  ones stay), **Show All…** (the full ⌘⇧J panel, which now shows active rows
  too).

## Quiet by design

- The "Downloading x" line still appears — it is how you learn something
  started. The "Saved x" and "Download failed" lines do **not** appear while
  the door is on screen; the check and the dot say it. With the sidebar folded
  or a page immersed there is no door, so the lines return.
- If Copper is not the active app when a download finishes, the Dock icon
  bounces once (`requestUserAttention(.informationalRequest)`). No
  notifications, no badges.
- Settings › General › Downloads still chooses the folder and whether to ask where to
  save each file; the save panel flow is unchanged.

## Bench

Probe worlds only (`SEARCH_PROBE=<world>`; files land in that world's own
`Downloads` folder, never `~/Downloads`).

```
./bench --world W downloads                 # rows: id, name, state, done, total, fraction, speed, file; unseen, doorShowing
./bench --world W downloads start URL       # download URL in the active tab
./bench --world W downloads open|close      # the popover
./bench --world W downloads cancel ID | retry ID | clear
python3 docs/fixtures/slow-download.py 8765 # a throttled server for real progress
#   /big?mb=20&kbps=2000   sized, throttled
#   /unknown?mb=5&kbps=1500  chunked, no Content-Length
#   /fail?mb=10&at=0.4     closes the socket at 40 % — once per URL; the retry finishes
#   /tiny.bin              an immediate attachment
```

WebKit numbers mouse buttons and reports download progress in its own ways;
the model (`Fork/Downloads.swift`) observes `WKDownload.progress` by KVO and
samples the byte count every half second for the speed — WebKit does not fill
`Progress.throughput`.
