# Demo

`demo.tape` renders the terminal demo used in the repository README. Run it from the repository root:

```sh
bash scripts/render-demo.sh
```

The script creates a temporary app to warm the pinned compiler, then renders `demo.gif` with [VHS](https://github.com/charmbracelet/vhs). The first app build runs hidden, so the GIF stays under a minute; the README footnote states the cold build time. The tape also sets `Snails.logger.level = :warn` off-camera, so the terminal shows the loop instead of the request records.

Requirements: `vhs`, `ttyd`, and `ffmpeg`, plus the `snails` CLI on `PATH`. To render by hand from a checkout, `mise install aqua:charmbracelet/vhs aqua:tsl0922/ttyd` installs the two tools; activate them or add their paths for the run.
