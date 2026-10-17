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
js/main.js        loads the data, builds the cards and the D3 chart
data/             JSON exported from R (versioned)
assets/fonts/     One Slice (not versioned: licence to settle before deploy)
```
