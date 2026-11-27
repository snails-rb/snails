# Demo

`demo.tape` renders the scaffolded posts API demo used in the repository README. Run it from the repository root:

```sh
bash scripts/render-demo.sh
```

The script creates a temporary app to warm the pinned compiler, then renders `demo.gif` with [VHS](https://github.com/charmbracelet/vhs). The first app build and test run are hidden, so the GIF stays under 90 seconds; the README footnote states the cold build time. The tape also defines hidden wrappers that mute the tools' progress lines, the bundle-cache note, and development logs off-camera, so the recording shows the plain commands and their results.

Requirements: `vhs`, `ttyd`, and `ffmpeg`, plus the `snails` CLI on `PATH`. To render by hand from a checkout, `mise install aqua:charmbracelet/vhs aqua:tsl0922/ttyd` installs the two tools; activate them or add their paths for the run.
