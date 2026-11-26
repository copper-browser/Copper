# Live folders — a sidebar folder that fills itself

*New Tab's right-click menu or ⌘K › New Live Folder: GitHub Pull Requests.
Code: `Sources/Search/Fork/LiveFolders.swift` (GitHub, the store),
`LiveFoldersUI.swift` (the column, the token sheet). Tests: `swift test
--filter LiveSharedFolders`, end to end: `docs/fixtures/folders-e2e.sh`.*

Dia's and Ardia's live folders list things from a service and keep the list
current. Copper's first source is GitHub: your open pull requests and the
ones waiting for your review.

## What the person sees

- A folder at the foot of Saved, with a pull-request glyph: the review
  requests first (an eye), then yours, newest first; drafts in grey. Hover a
  row for the repository, number and author.
- A copper dot on a pull request that is new or changed since you last
  opened it; a shut folder shows how many. The first fill lights nothing —
  what is there already isn't news.
- Click a row: the tab it is already open in, else a new tab. Right-click:
  Open in Background, Copy Link, Mark as Read. The folder's menu: Refresh,
  Mark All as Read, Show (both / review requests / yours), Rename, GitHub
  Token…, Remove.
- It refreshes every five minutes, on Refresh (the arrow under the pointer),
  and when the token changes.
- Without a token, or with one GitHub refuses, the folder says so in a row
  that opens the token sheet. A rate limit says when it tries again.

## The token

The sheet takes a pasted token (**Make a Token…** opens GitHub's page with
the `repo` scope ticked, so private repositories show too; a fine-grained
token with Pull requests: read works) or **Use GitHub CLI**, which asks
`gh auth token` once. Copper checks it with `GET /user`, then keeps it in the
login keychain (`Copper GitHub Token`, this Mac only; test worlds keep a 0600
file). It is sent only to api.github.com, over an ephemeral session (no
cookies, no disk cache).

A github.com sign-in in a tab isn't used: WebKit's cookies can't call the
API, and scraping the page would break with GitHub's next redesign.

## How it works

Two search requests per refresh, whatever the number of folders:
`is:pr is:open archived:false review-requested:@me` and `… author:@me`
(50 each, by last update). A folder keeps, per pull request, the
`updated_at` it had when you opened it; a different one is a dot. A 403/429
rate limit pauses automatic refreshes until GitHub's reset time.

## Limits

- GitHub only, and only pull requests: no checks, stacks, issues, Linear or
  Docs folders yet.
- One token for every folder.
