export const meta = {
  name: 'copper_arc_gauntlet',
  description: 'Gauntlet Loop: builder/critic rounds pushing Copper's Tier 1 surfaces — sidebar, command bar, split view, folders — to Arc grade, judged on screenshots beside real Arc screenshots.',
  phases: [{ title: 'Surfaces' }, { title: 'Smoothing' }],
};

const ROOT = '/Users/collinrijock/Developer/Copper';
const TREES = '/Users/collinrijock/Developer/Copper-gauntlet';
const BRIEF = `${ROOT}/.gauntlet/BRIEF.md`;
const BUILDER = 'anthropic/claude-opus-5';
const CRITIC = 'anthropic/claude-opus-5';
const SMOOTHER = 'anthropic/claude-fable-5-1';
const MAX_ROUNDS = args?.maxRounds ?? 4;

const pieces = {
  sidebar: {
    title: 'Sidebar: Arc-grade space sidebar — favicons, space tint, favourites grid, pinned/today split, space strip',
    from: 'fork',
    refs: ['arc-sidebar-exowatt.png', 'arc-command-bar-google-search.png'],
    scenario: `.gauntlet/run.sh g-sidebar . lands on the Exowatt space (6 favourites + 25 pinned + open tabs). Shoot that. Then \`./bench --world g-sidebar spaces select 0\` (Casual, 154 tabs) and shoot again — the long-list case must still look composed.`,
    writeSet: [
      'Sources/Search/Fork/** (new files welcome: e.g. SpaceTint.swift, PinGrid.swift)',
      'Sources/Search/Side.swift (the sidebar itself — reshape as needed, smallest diff that gets the result, logged in PATCHES.md)',
      'Sources/Search/Fork/Spaces.swift (SpaceStrip)',
      'Sources/Search/Tab.swift / Favicons.swift — hooks only, if favicons need a nudge',
      'Sources/Search/Palette.swift / Metrics.swift — only to add, never to change an existing value',
      'PATCHES.md',
    ],
    scope: `Make Copper's sidebar read as Arc's sidebar. Concretely: (1) favicons — the favourites grid shows 16–20pt favicons on soft squares (not letters), every tab row shows a 16pt favicon (fall back to the monogram only when none is cached; fetch on wake as upstream already does); (2) the whole sidebar is washed with the current space's hue (Space.hue is on the model; Arc uses roughly 8–12% saturation in light mode, deeper in dark) and the active row is a pill in a stronger tint of the same hue; (3) the favourites grid survives any count — rows of 3 or 4 squares, wrapping, never widening past the sidebar or clipping under the traffic lights (today the sidebar starts scrolled with the grid hidden — fix that); (4) a quiet separation between pinned tabs and today's tabs: a hairline or spacing plus a "New Tab" row with a + glyph, Arc-style; (5) the space strip at the foot becomes Arc's: the current space's name/emoji on the left, the other spaces as small tinted dots, a + at the end; (6) density — 13px text, ~28pt rows, 16pt icons, 12pt left inset, no hard borders anywhere. Titles truncate with an ellipsis; a long list scrolls under a soft fade, not a hard edge. Keep every existing interaction (click, close, pin/unpin, drag reorder, context menus, ⌃1–9) working.`,
  },
  commandbar: {
    title: 'Command bar: ⌘K as Arc\'s ⌘T — floating card, big input, icon rows, right-side hints',
    from: 'fork',
    refs: ['arc-command-bar-google-search.png', 'arc-command-bar-raindrop.png'],
    scenario: `After .gauntlet/run.sh g-commandbar .: \`./bench --world g-commandbar summon "goo"\` and shoot (mixed offers: pages in this and other spaces, history, bookmarks, a search). Then \`summon ""\` and shoot (the empty state). Then \`summon "split"\` and shoot (a command row). Close with \`bar ""\`.`,
    writeSet: [
      'Sources/Search/Fork/CommandBar.swift and new files under Sources/Search/Fork/',
      'Sources/Search/Omnibox.swift (the row/panel views — hooks or restyling, logged in PATCHES.md)',
      'Sources/Search/History.swift — additive only (e.g. a subtitle/hint field on Suggestion)',
      'PATCHES.md',
    ],
    scope: `The ⌘K bar must look like Arc's ⌘T: one floating card ~640pt wide centred horizontally about a third of the way down the window, 12–14pt corner radius, soft large shadow, no visible border, page dimmed slightly behind it. Input row ~56pt tall with a magnifier glyph and 17–18pt text. Result rows ~40pt: a 16–18pt icon on the left (favicon for pages/bookmarks, a glyph for commands, a magnifier for searches), the title in primary text, the URL/host or space name in muted text after it, and on the right a muted hint that says what Enter does ("Switch to Tab", "Open", "Search Google", "Run", "· Exowatt" for another space's tab). The selected row is a soft filled pill (Arc uses the space tint; we can too). Sections may be grouped (Tabs / Commands / History) with tiny muted headers only if it reads calmer. The empty state shows open tabs in this space and a few commands, not nothing. Keep keyboard behaviour: ↑↓ move, Enter runs, Esc closes, typing filters live.`,
  },
  split: {
    title: 'Split view: Arc-style panes — rounded cards, gutter, per-pane toolbar, active outline',
    from: 'fork',
    refs: ['arc-split-view.png', 'arc-command-bar-google-search.png'],
    scenario: `After .gauntlet/run.sh g-split .: \`./bench --world g-split tabs\` and pick two tabs with real sites (e.g. Lightspeed hosted and the Confluence wiki, or open two with \`./bench --world g-split open https://en.wikipedia.org\` and \`open https://example.com\`). \`select A\`, then \`split B\`, wait ~4s for both to render, shoot. Then \`select B\` (focus moves to the other pane) and shoot. \`split off\` when done.`,
    writeSet: [
      'Sources/Search/Fork/Split.swift and new files under Sources/Search/Fork/',
      'Sources/Search/App.swift — the existing SplitStage hook only',
      'Sources/Search/Sleep.swift / Browser.swift — hooks only if focus/sleep needs it, logged',
      'PATCHES.md',
    ],
    scope: `Make the split read as Arc's: both panes are rounded cards (10–12pt radius) floating in the page area with an 8pt gutter between them and a 6–8pt margin around, the page background showing through. Each pane carries a hairline toolbar (~32pt): back/forward glyphs, the tab's favicon and title or pretty URL centred/leading in muted text, a × on the right that closes that pane's tab (and thereby the split). The focused pane has a 2pt outline in the space tint (or the accent); the other pane has none. The divider is invisible until hovered, then a soft 4pt handle; dragging resizes with the existing fraction; double-click on it resets to 50/50. Clicking anywhere in the unfocused pane focuses it (existing Tab.touched path). The sidebar should show which tabs are in the split (a subtle ⫽ glyph or a linked pair) — small and optional if time is short. Keep ⌘⇧D toggling and \`bench split\` working.`,
  },
  sections: {
    title: 'Sections: Arc\'s three — Favourites grid, Saved tabs, Today (auto-archived after 24h)',
    from: 'gauntlet/sidebar',
    refs: ['arc-sidebar-exowatt.png', 'arc-command-bar-google-search.png'],
    scenario: `After .gauntlet/run.sh g-sections .: the Exowatt space — Arc's 25 pinned tabs must sit in the Saved section above the hairline + "New Tab" row, Arc's open tabs below it as Today. Shoot. Then \`./bench --world g-sections open https://example.com\` (a fresh Today tab appears under New Tab) and shoot. Then \`./bench --world g-sections sections save ID\` on that tab (it moves above the seam) and shoot. Then \`./bench --world g-sections sections archive\` (runs the 24h sweep now; imported Today tabs older than a day vanish; \`tabs\` confirms) and shoot.`,
    writeSet: [
      'Sources/Search/Fork/Sections.swift (new) and other new files under Sources/Search/Fork/',
      'Sources/Search/Fork/Spaces.swift (the `carried` set becomes the persisted `saved` set; restore/shape read and write it)',
      'Sources/Search/Side.swift — the carried/today views only: rename to saved/today, drag a row across the seam toggles saved',
      'Sources/Search/Session.swift — additive optional fields only (Entry.saved: Bool?, Entry.seen: Double?)',
      'Sources/Search/Fork/SettingsFork.swift — one row: archive Today after 12h / 24h / 48h / never',
      'Sources/Search/TabBar.swift — one line in TabMenu: Save / Unsave (or put it in GroupMenu\'s neighbour in Fork/)',
      'Sources/Search/Fork/Fork.swift — bench dispatcher case `sections`',
      'arc-import — Arc pinned → saved: true; unpinned → today with seen from data.tab.timeLastActiveAt (Apple epoch: +978307200 for Unix)',
      'bench — the sections verb',
      'PATCHES.md',
    ],
    scope: `Arc's sidebar is three sections and Copper's must be the same three, for real, not by heuristic. (1) Favourites: the existing pin grid — leave it. (2) Saved: tabs you keep. Today the sidebar branch approximates this with Spaces.carried = "whatever was restored"; replace that with an explicit, persisted flag: Session.Entry.saved (additive; an upstream-shaped file with no flag restores everything as saved, so nothing regresses). arc-import marks Arc's per-space pinned tabs saved and Arc's unpinned as not. (3) Today: everything else, under the hairline and the "New Tab" row, newest at the top like Arc. A tab moves between the two by dragging it across the seam, by a Save / Unsave item in its context menu, and by bench: sections save ID | unsave ID. Groups (folders) live in Saved; a Today tab that joins a group becomes saved. Auto-archive: each tab remembers when it was last active (Entry.seen, additive; set on select and on load); on launch and every 30 minutes, Today tabs not seen for the configured window (default 24h; Settings row 12h/24h/48h/never in Felipe's SettingsFork.swift) are closed through the normal close path so they land in the reopen-closed-tab list (Recall) — never lost. bench: sections archive runs the sweep now; sections lists saved/today counts per space. Visual: the seam stays as the sidebar branch drew it (hairline + New Tab); Saved scrolls without limit, Today takes only what it needs, Arc-style; a subtle "Today" caption above the today list only if it reads calmer than none (Arc has none — prefer none). Keep density and tint exactly as the sidebar piece has them; this is a model change with a small view delta, not a restyle.`,
  },
  folders: {
    title: 'Folders: Felipe\'s tab groups drawn as Arc folders — nested, chevron, indent',
    from: 'gauntlet/sections',
    refs: ['arc-sidebar-exowatt.png', 'arc-command-bar-google-search.png'],
    scenario: `After .gauntlet/run.sh g-folders .: \`./bench --world g-folders spaces select 0\` (Casual — 14 imported folders: Saved Sites, Web Inspo, Misc with nested LOTFG/BuildrFi/…, Ent) and shoot with folders collapsed — "Misc" must appear once with its children nested under it, not as flat "Misc › BuildrFi › …" rows. \`./bench --world g-folders groups toggle Misc\` then \`groups toggle "Misc › BuildrFi"\` and shoot the expanded tree. Also shoot Exowatt (Misc, Benefits).`,
    writeSet: [
      'Sources/Search/Fork/GroupsUI.swift, Groups.swift (Felipe\'s; extend, do not rewrite — nesting, header style, toggle verb, New Folder Inside)',
      'new files under Sources/Search/Fork/',
      'Sources/Search/Side.swift — only if the header row needs the sidebar\'s row metrics exposed',
      'PATCHES.md',
    ],
    scope: `Copper's folders ARE Felipe's tab groups (Fork/Groups.swift, GroupsUI.swift; docs/groups.md; ./bench groups). Do not build a second model and do not touch Session. Make groups render like Arc folders: (1) nesting from names — arc-import writes a nested Arc folder as "Parent › Child"; a group whose name starts with another group's name + " › " is its child: draw only the last segment, indent 16pt per level under the parent's header, and collapsing a parent hides its children (headers and tabs); (2) header row at the sidebar's row height: a chevron that rotates on expand, a folder glyph tinted with the group's hue (or the space hue when nil), the name in medium 13px, a muted count on the right only while collapsed; children's tab rows indent 16pt (plus 16 per level); (3) keep Felipe's interactions (click header toggles; header context menu rename/recolour/ungroup/close all; tab › Group ›; drag between members joins) and add New Folder Inside on a header, which creates "<parent> › <name>"; (4) bench: groups toggle NAME collapses/expands (NAME may be the full "A › B" name or the last segment if unique). Folders live in the Saved section (the sections piece you branch from); a Today tab joining a group becomes saved. Style must match the sidebar you are branched from; do not restyle the sidebar itself.`,

  },
};

function tree(key) { return `${TREES}/${key}`; }

function builderPrompt(piece, round, feedback) {
  const setup = round === 0
    ? `If \`${tree(piece.key)}\` is missing run \`git -C ${ROOT} worktree add -B gauntlet/${piece.key} ${tree(piece.key)} ${piece.from}\`. Then \`cd ${tree(piece.key)}\`.`
    : `\`cd ${tree(piece.key)}\` — your worktree from the previous round, with your commits.`;
  return `You are the BUILDER for one piece of a Gauntlet Loop on Copper, a Swift/SwiftUI/WebKit macOS browser. Read ${BRIEF} completely first; then read PATCHES.md, FORK-PLAN.md (the entry for this piece) and the Fork/ sources you will touch.

${setup}
Work only in that worktree, on branch gauntlet/${piece.key}. Your probe world is g-${piece.key}.
First: \`git merge fork\` (fork moved while the loop ran — Felipe's tab groups + MCP, the space swipe, arc-import folders; the BRIEF's "Late changes" section explains). Resolve conflicts keeping both intents; build must pass before you start your own work. The worktree may also hold uncommitted files from an earlier aborted attempt at this piece — review them, keep what fits the scope, delete the rest.

PIECE: ${piece.title}
SCOPE: ${piece.scope}
WRITE SET (edit nothing outside it):
- ${piece.writeSet.join('\n- ')}
REFERENCES to open and study with your image tool: ${piece.refs.map((r) => `${ROOT}/.gauntlet/refs/${r}`).join(', ')}
HOW THE CRITIC WILL LOOK AT IT: ${piece.scenario}

${round === 0
  ? 'Round 1. Look first: run `.gauntlet/run.sh g-' + piece.key + ' .` from your worktree, take the scenario shots into .gauntlet/shots/ (the .s.png half-size copies are what you open), read the code that draws them, then build. Aim for the whole scope this round, not a sliver.'
  : `Round ${round + 1}. A fresh critic compared your last round with Arc and Arc won. Their verdict:\n\n${feedback}\n\nClose that gap first, then anything else you notice. Do not argue with the critic; fix it.`}

Finish the round only when: \`./build.sh debug app\` passes in your worktree, the app launches via run.sh and the scenario works through the bench with no crash (check /tmp/copper-g-${piece.key}.log), every upstream file you touched has a PATCHES.md row, you have taken the scenario shots to ${ROOT}/.gauntlet/shots/${piece.key}-r${round + 1}-<what>.png (use \`.gauntlet/shot.sh g-${piece.key} ${ROOT}/.gauntlet/shots/${piece.key}-r${round + 1}-<what>.png .\`), and your files are committed on gauntlet/${piece.key}. Then quit your instance: \`.gauntlet/stop.sh g-${piece.key}\` (the critic relaunches). Reply with ≤10 lines: what changed, shot paths, anything you could not do.`;
}

function criticPrompt(piece, round) {
  return `You are a fresh, ruthless product-design CRITIC in a Gauntlet Loop. You have no history with the builder; judge only what renders.

Read ${BRIEF} (sections "The bar", "What Arc feels like", "Running and screenshotting", "Progress page"). Then:
1. \`cd ${piece.dir ?? tree(piece.key)} && git log --oneline -5 && ./build.sh debug app\`. If the build fails → verdict FAIL, biggest gap = the error, skip to step 5.
2. Take your OWN screenshots: \`.gauntlet/run.sh g-${piece.key} .\` then exactly this scenario — ${piece.scenario} — saving to ${ROOT}/.gauntlet/shots/${piece.key}-r${round + 1}-critic-<what>.png via \`.gauntlet/shot.sh g-${piece.key} <path> .\`. If the app crashes or the bench does not answer, that is a FAIL with the log (/tmp/copper-g-${piece.key}.log) as the gap.
3. Open the .s.png copies and the references ${piece.refs.map((r) => `${ROOT}/.gauntlet/refs/${r}`).join(', ')} with your image tool. Compare as a senior product designer would: hierarchy, density, alignment, type scale, icon quality (favicons vs letters), tint and contrast, hairlines vs hard borders, spacing rhythm, whether the piece looks like it belongs to the same product as Arc's version, anything that reads as "prototype" or "default SwiftUI". Also try one interaction through the bench that the scope promises (e.g. select another tab, switch space, summon with other text) and make sure it holds.
4. Decide: would a designer shown both call ours the clearly weaker one? If yes → FAIL and name the ONE biggest remaining gap concretely (what, where, what it should be, with pt values or the reference detail to match). If ours holds up next to Arc for this piece's scope ("${piece.title}") → PASS. Do not pass a piece whose favicons are letters, whose panel has a hard 1px border, or whose text sizes are visibly larger than Arc's.
5. Append a <section> to ${ROOT}/.gauntlet/progress.html (piece ${piece.key}, round ${round + 1}, PASS/FAIL, biggest gap, your primary shot beside the reference; paths relative to .gauntlet/). Append only; never rewrite earlier sections.
6. Quit the instance you launched: \`.gauntlet/stop.sh g-${piece.key}\`.

Piece scope for context (judge only this; ignore surfaces other pieces own): ${piece.scope}

Return JSON only.`;
}

const verdictSchema = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    biggestGap: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['pass', 'biggestGap', 'notes'],
};

async function gauntlet(key) {
  const piece = { key, ...pieces[key] };
  const history = [];
  let feedback;
  for (let round = 0; round < MAX_ROUNDS; round++) {
    log(`[${key}] round ${round + 1} — build`);
    const built = await agent(builderPrompt(piece, round, feedback), {
      label: `${key}-build-${round + 1}`, model: BUILDER, thread: `builder:${key}`,
    });
    log(`[${key}] round ${round + 1} — critique`);
    const verdict = await agent(criticPrompt(piece, round), {
      label: `${key}-critic-${round + 1}`, model: CRITIC, schema: verdictSchema,
    });
    history.push({ round: round + 1, built: built ?? null, verdict: verdict ?? null });
    if (!verdict) { feedback = 'Critic returned nothing; re-verify build, relaunch, retake the scenario shots, then tighten polish.'; continue; }
    log(`[${key}] round ${round + 1} — ${verdict.pass ? 'PASS' : 'FAIL: ' + verdict.biggestGap}`);
    if (verdict.pass) break;
    feedback = `${verdict.biggestGap}\n\nNotes: ${verdict.notes}`;
  }
  return { key, rounds: history.length, passed: !!history.at(-1)?.verdict?.pass, history };
}

// Foundation (the sidebar piece) passed in run copper-arc-gauntlet-muef99k8-rs3z7p
// (round 2), and gauntlet/sidebar has since been merged with fork by hand.
phase('Surfaces');
const [commandbar, split, [sections, folders]] = await parallel([
  () => gauntlet('commandbar'),
  () => gauntlet('split'),
  async () => { const a = await gauntlet('sections'); const b = await gauntlet('folders'); return [a, b]; },
]);

phase('Smoothing');
const smooth = await agent(`You are the SMOOTHING agent at the end of a Gauntlet Loop on Copper (${ROOT}, branch fork). Read ${BRIEF} and PATCHES.md. Builders worked in separate worktrees on separate branches: gauntlet/sidebar → gauntlet/sections → gauntlet/folders (each branched from the previous; folders contains all three), and gauntlet/commandbar, gauntlet/split (from fork, each merged fork again at their start). Your job:
1. In ${ROOT} on branch fork (\`git pull --ff-only\` first; Felipe pushes here too): merge gauntlet/folders (which contains sidebar + sections), then gauntlet/commandbar, then gauntlet/split. Resolve conflicts by keeping both intents (Side.swift and Fork/ files are where they will meet); \`./build.sh debug app\` must pass after each merge. Do not rebase or rewrite history; plain merges are fine here.
2. Make it feel like one product: \`.gauntlet/run.sh g-final\` in ${ROOT} and walk every surface with shots to .gauntlet/shots/final-<what>.png — Exowatt sidebar, Casual with folders open and closed, ⌘K with "goo" and empty, a split of two real pages, the space strip after \`spaces next\`, the Saved/Today seam after \`open https://example.com\`, and dark mode (\`./bench --world g-final ui look dark\` if the look setting exists, else skip). Fix inconsistent radii, tints, type sizes, spacing, leftover hard borders, glyph styles that differ between pieces, anything that crashes or logs errors in /tmp/copper-g-final.log. Also confirm ⌘K's "Switch to <space>", split via ⌘⇧D's bench twin, and folder toggling all still work through the bench.
3. PATCHES.md must list every upstream file the merged fork now touches, one row per hook group; COLLIN.md's status table gets a line per piece (shipped / partly). Commit in small logical commits on fork and push (\`git push\`). Do not touch main.
4. Remove the worktrees when done: \`git worktree remove --force ${TREES}/<piece>\` for each of sidebar, sections, folders, commandbar, split, and \`git branch -D gauntlet/<piece>\` only after confirming its commits are in fork (\`git branch --merged fork\`). Then \`.gauntlet/stop.sh all\` — no gauntlet Copper may be left running.
5. Append a final "Smoothing" section to .gauntlet/progress.html with before/after pairs for the sidebar and ⌘K (before-*.png vs final-*.png).
Reply with ≤15 lines: what you unified, what is still visibly unfinished, the merge commits.`, { label: 'smoothing', model: SMOOTHER });

const finalVerdict = await agent(criticPrompt({
  key: 'final',
  dir: ROOT,
  title: 'Whole browser: Copper Tier 1 beside Arc',
  refs: Object.keys(pieces).flatMap((k) => pieces[k].refs).filter((v, i, a) => a.indexOf(v) === i),
  scenario: `In ${ROOT} (branch fork, not a worktree — use \`.gauntlet/run.sh g-final\` and \`.gauntlet/shot.sh g-final <path>\` without a checkout argument): shoot the Exowatt sidebar, \`spaces select 0\` Casual with a folder expanded, \`summon "goo"\` then \`bar ""\`, and a split of two real pages.`,
  scope: 'The entire Tier 1 surface — sidebar with spaces/favourites/folders, command bar, split view — judged as one product against Arc.',
}, 0), { label: 'final-critic', model: CRITIC, schema: verdictSchema });

return { commandbar, split, sections, folders, smoothing: smooth ?? null, finalVerdict: finalVerdict ?? null };
