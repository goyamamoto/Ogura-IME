# データの扱い

入力した内容の扱いは次のとおりで、各項目は `Core/Tests/CoreTests/SecurityTests/DataProtectionTests.swift` のテストで固定しています。


| 保証            | 内容                                                                                                                                                                               | テスト                                                                             |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| ネットワークに出ない    | 変換モデル（Zenzai の genmai と zenz-v3.2-small）は端末内で動く。アプリ本体と Core に通信 API の呼び出しがなく、entitlements にもネットワーク権限がない                                                                                                     | `noNetworkCodeInSources`, `entitlementsGrantNoNetworkAccess`                    |
| 入力内容をログに残さない  | 入力を扱うコードは標準出力に書かず、`os.Logger` への出力は `privacy: .private` を明示したものに限る                                                                                                               | `inputHandlingCodeDoesNotLogInput`                                              |
| 読む文脈は少量に限る    | 変換精度のためカーソル前後の最大30文字をホストアプリから読む。端末内で使い、保存しない                                                                                                                                     | `hostContextReadIsBounded`                                                      |
| 続きを書くときだけ広く読む | 続きを書くキー（Shift+Tab、Ctrl+/、F19）を押したときに限り、カーソルの前の最大400文字を読んで Mac の中のモデル（Foundation Models か MLX）に渡す。通信はせず、保存もしない                                                                    | `continuationContextIsReadOnlyOnKeyAndBounded`                                  |
| 学習データの保存先     | 確定した語と読みの組はアプリ自身のコンテナ `~/Library/Containers/org.if0.inputmethod.ogura/Data/Library/Application Support/Ogura/` 配下にだけ書く。共有コンテナ（App Group）は使わない。暗号化はしないので、不要なら設定の「履歴学習」を「学習を無視」にする | `learningDataLivesInUserContainer`, `learningDataIsWrittenOnlyToGivenDirectory` |
| 依存の出どころ       | 依存パッケージはコミットで固定し、azooKey / goyamamoto（変換エンジンのフォーク）/ Apple / ensan-hcl / johnmai-dev / ml-explore / huggingface / swiftlang / ibireme の GitHub リポジトリに限る                                                    | `dependenciesArePinnedToKnownSources`                                           |


macOS はパスワード欄などのセキュア入力中に IME を無効化するため、パスワードが IME を経由することはありません。
