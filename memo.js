const fs = require("fs");
const { parse } = require("csv-parse/sync");

// CSV読み込み
const csv = fs.readFileSync(
    "/Users/amania/Downloads/Appleメディアサービス情報 パート1/2/Apple_Media_Services/Apple Music Activity/Apple Music - Play History Daily Tracks.csv",
    "utf-8",
);

// パース（クォート対応）
const records = parse(csv, {
    columns: true, // ヘッダーをキーにする
    skip_empty_lines: true,
});

// 重複排除
const trackSet = new Set();

for (const row of records) {
    const trackId = row["Track Identifier"]; // ←ここ重要

    if (trackId) {
        trackSet.add("https://music.apple.com/jp/song/" + trackId.trim());
    }
}

// 配列化
const trackArray = [...trackSet];

// JSON保存
fs.writeFileSync(
    "track_ids.json",
    JSON.stringify(trackArray, null, 2),
    "utf-8",
);

console.log(`保存完了: ${trackArray.length}件`);
