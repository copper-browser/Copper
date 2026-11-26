**Copper is now signed by Exowatt Inc** (Apple Developer ID, team 62D5L6T44Y), notarized as before.

**On Copper 1.0.20261126.124 or older?** That version refuses this update (*"isn't signed with Copper's release certificate"*), because it only accepts the team that signed it before. Reinstall once, over the old copy; your settings, spaces, tabs and passwords stay:

```sh
brew upgrade --cask copper
```

or download the disk image or zip below. From this version on, Copper accepts updates signed by either team and updates itself again. macOS asks once more for Full Disk Access and Files & Folders (System Settings › Privacy & Security), and the keychain may ask once per saved password before Copper moves it into its own keychain group, where it stops asking.
