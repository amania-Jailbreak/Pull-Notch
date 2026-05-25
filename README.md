# Pull Notch

macOSにカスタマイズ可能なDynamic islandを追加するアプリ

## 動作確認環境

- M5 macbook air (macOS Tahoe 26.4)

## 機能

- 音楽コントロールおよびビジュアライザー
- 天気
- ポモドーロタイマー
- ファイルのピン留め
- プラグイン
- プラグイン経由の他アプリケーションとの連携

## 使い方

- カーソルを島に当てると再生中の場合曲名が出てきます
- 島をクリックする もしくはスワイプすると島が開きます
- 開いてる最中にスワイプするとページを切り替えられます
- ファイルを島にドラックアンドドロップするとファイルをピン留めできます

## プラグインシステム

ReleaseページにSwift向けフレームワークを公開しております ドキュメントは後日公式ページにて公開いたします

## ローカル連携API

Pull Notchは `localhost:38591` でJSON newline形式の簡易ブリッジを受け付けます。プラグインを作らなくても、外部ツールからウィジェットや拡張ページを登録できます。

### プログレスウィジェット

```json
{"id":"1","method":"setWidget","clientID":"build","widget":{"id":"progress","title":"Build","placement":"trailing","kind":"circularProgress","systemName":"hammer.fill","progress":0.42,"isActive":true,"text":"42%"}}
```

### ボタンとテキストボックス付きページ

```json
{"id":"2","method":"setPage","clientID":"deploy","page":{"id":"panel","title":"Deploy","preferredWidth":420,"elements":[{"type":"headline","text":"Deploy"},{"type":"progress","label":"Build","value":0.62},{"type":"textField","id":"message","label":"Message","placeholder":"Release note"},{"type":"button","title":"Start","systemName":"paperplane.fill","postURL":"http://localhost:3000/deploy","body":{"message":"$message"}}]}}
```

ボタンは `POST` のみ実行します。`https` URL、または `http://localhost` / `http://127.0.0.1` / `http://[::1]` が指定できます。

### 動作確認

Pull Notchを起動した状態で、以下を実行するとウィジェットと拡張ページを登録し、ページ内ボタンのPOST先もローカルで受けます。

```bash
python3 scripts/test_bridge_api.py
```

## ダウンロード

[こちらからdmgファイルをダウンロードしてください](https://github.com/amania-Jailbreak/Pull-Notch/releases/latest)

## 追伸

Pull Notchはさまざまなアプリからアイデアを得ています そしてプログラムをお借りしています

- [Media Remote Adaptor](https://github.com/ungive/mediaremote-adapter/) BSD 3-Clause Licenseの本文は別ファイルに記してあります
