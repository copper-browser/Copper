# Roadmap

What is being worked on, what comes next, and what is not on the list, with
where each request came from: GitHub issues, pull requests, and the replies
to the launch on X. Anything finished moves to the **Unreleased** section of
[CHANGELOG.md](CHANGELOG.md), which becomes the next update.

Want something that isn't here? [Open an issue](https://github.com/copper-browser/Copper/issues).
Want to build something that is? Say so on its issue first, so two people
don't build it twice.

## Now — fixes for the next update

- [ ] **Tab moves between a page's fields**, as it does everywhere else; ⌃Tab and ⌃⇧Tab switch tabs. Today Tab walks the tabs, even in a form. *(X)*
- [ ] **Password managers**: Bitwarden goes blank after signing in, and 1Password won't sign in. *(X, several)*
- [ ] **⌘1–⌘9 reach the right tab**, pinned ones included, on every keyboard layout. *(X, several)*
- [ ] **Dragging tabs to reorder them** in the row across the top. *(X)*
- [ ] **A double-click on the title bar fills the screen** from anywhere along the top, in both layouts. *(X)*
- [ ] **Passkeys on some sign-ins** (Google's "Use your passkey"). The page bridge's parent-domain mismatch is fixed and covered by synthetic tests ([passkey checks](docs/passkeys.md#regression-checks)); live Google sign-in still needs validation on a signed release. *(X)*
- [x] **Google sign-in reloads in a loop** with the iCloud Passwords extension installed. A password manager's frame on the page asked WebKit for its tab, WebKit ended the page's process, and Copper loaded it again for ever; the shim no longer asks from a frame, and a page that keeps crashing stops and says so.
- [ ] README: the size reads 2 MB in one place and 5 MB in another; 1.0 is 2.9 MB.

## Next — small additions people asked for

- [ ] **Web Inspector**: right-click › Inspect Element. *(X)*
- [ ] **Middle-click closes a tab.** *(X)*
- [ ] **The sidebar hides by itself** until the pointer reaches the edge, as an option on top of ⌘S. *(X, several)*
- [ ] **The address field holds still** on a new tab while its suggestions unroll under it. *(X)*
- [ ] **A setting to turn off the reading-progress fill** in the tab you are on. *(X)*
- [ ] **Import from Comet**, alongside Chrome, Arc, Brave, Edge and Dia. *(X)*
- [x] **Homebrew**: `brew install --cask copper-browser/copper/copper`. *(X)*
- [ ] **Intel Macs.** *(X)*

## Later — bigger pieces of work

- [ ] **Spaces**: separate sets of tabs, each with its own cookies, sign-ins and downloads folder, switched from the sidebar or a shortcut; sites that always open in a given space. The most asked-for feature. *(X, many)*
- [ ] **More of the extension APIs**: the side panel, and the proxy API VPN and proxy extensions rely on. *(X)*
- [ ] **An address bar that stays visible** above the page, as an option.
- [ ] **A tab switcher with previews** (⌃Tab held down). *(X)*
- [ ] **Your own keyboard shortcuts.** *(X)*
- [ ] **Driving Copper from an agent** (an MCP server over the bench), for automation and testing. *(X)*
- [ ] **Web push notifications**, as far as WebKit lets an app other than Safari have them. *(X)*
- [ ] **Smoother scrolling with a mouse wheel.** To look into. *(X)*
- [ ] **Tab groups.** To weigh against keeping the sidebar quiet. *(X)*

## Not on the list, for now

- **Windows and Linux in this app.** Copper for Mac is made of the Mac's own WebKit and AppKit; Windows and Linux are apps of their own.
- **macOS before 14.** The app leans on what macOS 14 added to WebKit.
