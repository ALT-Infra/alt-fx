#!/usr/bin/env bash
set -euo pipefail

mkdir -p /app/src /app/test
cat > /app/package.json <<'JSON'
{
  "type": "module",
  "bin": {
    "wordcount": "./src/index.js"
  },
  "scripts": {
    "test": "vitest run"
  },
  "devDependencies": {
    "vitest": "^3.0.0"
  }
}
JSON
cat > /app/src/index.js <<'JS'
#!/usr/bin/env node
import { readFileSync } from "node:fs";

export function countText(text) {
  const lines = text.length === 0 ? 0 : text.split(/\n/).length;
  const words = text.trim() === "" ? 0 : text.trim().split(/\s+/).length;
  return { words, lines, characters: text.length };
}

if (process.argv[1] && process.argv[1].endsWith("index.js")) {
  const file = process.argv[2];
  const counts = countText(readFileSync(file, "utf-8"));
  console.log(`words: ${counts.words}`);
  console.log(`lines: ${counts.lines}`);
  console.log(`characters: ${counts.characters}`);
}
JS
cat > /app/test/wordcount.test.js <<'JS'
import { describe, expect, test } from "vitest";
import { countText } from "../src/index.js";

describe("wordcount", () => {
  test("counts words lines and characters", () => {
    expect(countText("hello world\nagain")).toEqual({
      words: 3,
      lines: 2,
      characters: 17,
    });
  });
});
JS
chmod +x /app/src/index.js
chown -R agent:agent /app
