// Downloads the IBM Plex latin subsets as TTF into flutter/assets/fonts/.
//
// The web build fetched woff2 (see src/styles/fonts.css); Flutter wants TTF, so
// this asks Google Fonts with no User-Agent (which yields truetype URLs) and
// writes the binaries straight to disk. One face per file, weights 400-600 —
// the same set tokens.dart names.
const fs = require("fs");
const path = require("path");
const https = require("https");

const OUT = path.join(__dirname, "..", "flutter", "assets", "fonts");

const FAMILIES = [
  { css: "IBM+Plex+Sans", file: "plex-sans", weights: [400, 500, 600] },
  { css: "IBM+Plex+Serif", file: "plex-serif", weights: [400, 500, 600] },
  { css: "IBM+Plex+Mono", file: "plex-mono", weights: [400, 500] },
];

function get(url, headers = {}) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers }, (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () =>
          resolve({ status: res.statusCode, buffer: Buffer.concat(chunks) })
        );
      })
      .on("error", reject);
  });
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  for (const fam of FAMILIES) {
    for (const w of fam.weights) {
      const cssUrl = `https://fonts.googleapis.com/css2?family=${fam.css}:wght@${w}`;
      const css = await get(cssUrl);
      const text = css.buffer.toString("utf8");
      const m = text.match(/src:\s*url\(([^)]+\.ttf)\)/);
      if (!m) {
        console.error(`no ttf url for ${fam.file} ${w}`);
        process.exitCode = 1;
        continue;
      }
      const font = await get(m[1]);
      const dest = path.join(OUT, `${fam.file}-${w}.ttf`);
      fs.writeFileSync(dest, font.buffer);
      const magic = font.buffer.slice(0, 4).toString("hex");
      console.log(`${path.basename(dest)}  ${font.buffer.length} bytes  magic=${magic}`);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
