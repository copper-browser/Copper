## CI/CD

This repo builds on **Roadrunner** (Exowatt's Woodpecker + Dagger CI, `.woodpecker/`): the canvas pin check and hourly bump, the 6-hourly upstream sync, and the signed macOS release (`.woodpecker/release.yaml` on Roadrunner's Mac; docs/releasing.md). Check builds with `gh rr status`, `gh rr watch`, `gh rr logs`, `gh rr rerun` (install: `gh extension install Exowatt-Labs/gh-roadrunner && gh alias set rr roadrunner --clobber`) — `gh run` only sees GitHub Actions. Console: https://cicd.apps.exowatt.com.
