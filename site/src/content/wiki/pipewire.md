# PipeWire

::infobox PipeWire
作者 | Wim Taymans(Red Hat)、2015〜
役割 | 音声と映像のストリームを扱うサーバ
互換 | PulseAudio(pipewire-pulse)、JACK、ALSA のプラグイン
セッションマネージャ | WirePlumber
ame-shell | 音量と出力先の切り替え(ame-uzume)

**PipeWire** は、Linux の音声と映像を扱うサーバです。PulseAudio と JACK の役割を 1 つにまとめ、今は多くのディストリで標準になっています。

## ame-shell での使われ方 {#ame}

- 音量の変更と読み取りは小さな道具 `ame-uzume`(Odin。pipewire-pulse の口に libpulse で話す)。100% を超えないようにし、set した値を覚えてログインで戻します。
- 音量の**変化**は `ame-uzume watch` を常駐させて知ります(変わるたびに新しい値の 1 行。ポーリングしない)。
- 出力先の一覧と切り替えも `ame-uzume`(`list sinks` / `use sink 名前`)。Bluetooth のイヤホンをつないだときの高音質(A2DP)への切り替えも `ame-uzume profile` で行い、pactl は使いません。切り替えたときは、**再生中の音**も新しい機器へ移します([メディア](#/tech-media))。
- Bluetooth のイヤホンをつないだとき、マイクを開くアプリがあると通話用の低音質(HFP)に自動で切り替わる WirePlumber の設定を止めています([[a2dp-hfp]])。

## 関連項目 {#see}

- [[a2dp-hfp]] / [[mpris]]

## 参考文献 {#refs}

- [PipeWire の文書](https://docs.pipewire.org/)
