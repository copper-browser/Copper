## CI/CD

The canvas pin check and hourly bump and the 6-hourly upstream sync run on **Roadrunner** (Exowatt's Woodpecker + Dagger CI, `.woodpecker/`). Everything macOS (the signed release `release.yml`, `sync-fork.yml`) stays on GitHub Actions for now, and the site deploys with GitHub Pages (`site.yml`). Check Roadrunner builds with `gh rr status`, `gh rr watch`, `gh rr logs`, `gh rr rerun` (install: `gh extension install Exowatt-Labs/gh-roadrunner && gh alias set rr roadrunner --clobber`) — `gh run` only sees GitHub Actions. Console: https://cicd.apps.exowatt.com.
