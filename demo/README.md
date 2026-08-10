# Demo

This folder contains a [VHS](https://github.com/charmbracelet/vhs) tape that
generates the demo GIF shown in the project README.

## Regenerating

```bash
./make-demo.sh
```

Requires: `vhs`, `devjournal`, `tree`, `jq`.

## Keeping the demo current

When adding or changing CLI commands, update `devjournal-demo.tape` to cover the
new feature, then re-run `./make-demo.sh` and commit the updated GIF.
