Apple Silicon の Mac と macOS 15 以降で動きます。

## インストール

pkg を開いてインストールします（管理者のパスワードを求められます）。pkg は Apple の Developer ID で署名していないので、初めて開くときに macOS が止めます。「システム設定」>「プライバシーとセキュリティ」の一番下に出る「このまま開く」を押すと進みます。ターミナルから入れる場合、この手順は要りません。

```sh
sudo installer -pkg ~/Downloads/Ogura-*-unsigned.pkg -target /
```

インストールしたアカウントでは、すぐに入力ソースの一覧に Ogura が出ます。ほかのアカウントでは、ログインし直すと出ます。一覧に出ないときは、ログアウトして再ログインしてください。

1. 「システム設定」>「キーボード」>「入力ソース」>「編集…」>「+」>「日本語」から Ogura を追加
2. メニューバーの入力メニューから Ogura（「お」のアイコン）を選択

使い方は [README](https://github.com/goyamamoto/Ogura-IME#readme) と [docs/usage.md](https://github.com/goyamamoto/Ogura-IME/blob/main/docs/usage.md) にあります。
