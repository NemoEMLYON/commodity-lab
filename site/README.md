# Site

Static website of the project. Everything it shows comes from `data/*.json`,
written by `export_site.R` from the R pipeline's outputs.

## Preview locally

Browsers refuse to load the JSON files from `file://`, so serve the folder:

- VS Code: install the "Live Server" extension, open `site/index.html`,
  click "Go Live" (bottom right).
- Or, in a terminal inside `site/`: `python -m http.server 8000`, then open
  http://localhost:8000

## Structure

```
index.html        page structure
css/tokens.css    design tokens: colours, type, spacing (single source)
css/main.css      layout and components
js/hero.js        hero: real volatility traces + liquid-metal WebGL object
js/main.js        loads the data, builds the cards and the D3 chart, starts the sections
js/story.js       findings section (risk bars, timeline, 2x2, heatmap)
js/lab.js         the lab: forecasts vs outcome, scores, horizon panel
js/simulator.js   JS port of the R backtest (also runs in Node)
js/sim-ui.js      simulator controls and charts; loads its data when the section is near
tests/            node tests/test_simulator.js: JS vs 60 R reference cases
data/             JSON and CSV exported from R (versioned)
assets/fonts/     One Slice (not versioned: licence to settle before deploy)
```

## Deployment

GitHub Pages publishes this folder as it is (workflow in
`.github/workflows/pages.yml`). Without `assets/fonts/OneSlice.otf` the
headings fall back to Oswald / Arial Narrow / Impact.
