// build_map_geometry.js — projected outlines for the 3D weather map.
//
// Run once (the output is versioned), from the project root:
//   cd tools && npm install us-atlas@3.0.1 topojson-client@3.1.0 d3-geo@3.1.1 && cd ..
//   node tools/build_map_geometry.js
// Writes site/data/map_geometry.json: US states around the ten weather
// cities, projected to a flat plane (x to the east, y to the north, in map
// units), simplified, plus the city positions.
//
// Source: us-atlas 3.0.1 (ISC), a TopoJSON copy of the US Census Bureau's
// 2017 cartographic boundary files (public domain), clipped to shorelines,
// so the Great Lakes appear as water.

const fs = require("fs");
const path = require("path");
const topojson = require("topojson-client");
const d3 = require("d3-geo");

const atlas = require("us-atlas/states-10m.json");

// Same cities and coordinates as WEATHER_CITIES in R/01_data.R.
const CITIES = [
  ["new_york", 40.71, -74.01], ["boston", 42.36, -71.06], ["philadelphia", 39.95, -75.17],
  ["washington", 38.91, -77.04], ["pittsburgh", 40.44, -80.00], ["cleveland", 41.50, -81.69],
  ["detroit", 42.33, -83.05], ["chicago", 41.88, -87.63], ["minneapolis", 44.98, -93.27],
  ["atlanta", 33.75, -84.39]
];

// Region shown: from the Dakotas to Maine, Georgia to the Canadian border.
const WEST = -98.5, EAST = -66.5, SOUTH = 31.0, NORTH = 49.3;
const WIDTH = 1000;                 // map units across; height follows the shape

// Conic conformal projection centred on the region: shapes look right.
// d3 reads polygons on the sphere: the ring must turn clockwise, otherwise it
// means "the whole globe except this box".
const region = { type: "Polygon", coordinates: [[[WEST, SOUTH], [WEST, NORTH], [EAST, NORTH], [EAST, SOUTH], [WEST, SOUTH]]] };
const projection = d3.geoConicConformal().parallels([33, 45]).rotate([82.5, 0]).fitWidth(WIDTH, region);
const [[x0, y0], [x1, y1]] = d3.geoPath(projection).bounds(region);
const HEIGHT = y1 - y0;
projection.clipExtent([[x0, y0], [x1, y1]]);

// Ramer-Douglas-Peucker simplification of one ring (tolerance in map units).
function simplify(points, tol) {
  if (points.length < 4) return points;
  const keep = new Array(points.length).fill(false);
  keep[0] = keep[points.length - 1] = true;
  const stack = [[0, points.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [ax, ay] = points[a], [bx, by] = points[b];
    const len = Math.hypot(bx - ax, by - ay);
    let best = -1, dmax = 0;
    for (let i = a + 1; i < b; i++) {
      // Distance to the segment's line; to the point itself when the segment
      // has zero length (a closed ring starts and ends on the same point).
      const d = len < 1e-9 ? Math.hypot(points[i][0] - ax, points[i][1] - ay)
        : Math.abs((bx - ax) * (ay - points[i][1]) - (ax - points[i][0]) * (by - ay)) / len;
      if (d > dmax) { dmax = d; best = i; }
    }
    if (dmax > tol) { keep[best] = true; stack.push([a, best], [best, b]); }
  }
  return points.filter((_, i) => keep[i]);
}

// Project a GeoJSON geometry and collect its rings in flat coordinates
// (origin at the region's centre, y pointing north).
function rings(geometry) {
  const out = [];
  let ring = [];                    // a plain variable: d3's clipping calls these
  const stream = projection.stream({ // methods without `this` bound to our object
    polygonStart() {}, polygonEnd() {},
    lineStart() { ring = []; },
    point(x, y) { ring.push([+(x - x0 - WIDTH / 2).toFixed(1), +(HEIGHT / 2 - (y - y0)).toFixed(1)]); },
    lineEnd() { const r = simplify(ring, 0.9); if (r.length > 3) out.push(r); },   // drop slivers
    sphere() {}
  });
  d3.geoStream(geometry, stream);
  return out;
}

const states = topojson.feature(atlas, atlas.objects.states).features
  .map(f => ({ id: f.id, name: f.properties.name, rings: rings(f.geometry) }))
  .filter(s => s.rings.length > 0);

const cities = CITIES.map(([id, lat, lon]) => {
  const [x, y] = projection([lon, lat]);
  return { id, x: +(x - x0 - WIDTH / 2).toFixed(1), y: +(HEIGHT / 2 - (y - y0)).toFixed(1) };
});

const out = { width: WIDTH, height: +HEIGHT.toFixed(1), states, cities,
              source: "US Census Bureau cartographic boundary files 2017 (public domain), via us-atlas 3.0.1" };
const file = path.join(__dirname, "..", "site", "data", "map_geometry.json");
fs.writeFileSync(file, JSON.stringify(out));
const points = states.reduce((n, s) => n + s.rings.reduce((m, r) => m + r.length, 0), 0);
console.log(`${file}: ${states.length} states, ${points} points, ` +
            `${(fs.statSync(file).size / 1024).toFixed(0)} KB, height ${HEIGHT.toFixed(0)}`);
