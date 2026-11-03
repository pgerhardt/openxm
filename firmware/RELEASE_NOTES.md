# WH-1000XM3 firmware release notes

Checked against Sony sources on **2026-10-30**. Covers the international (`MDRID291600`), Japanese (`MDRID291601`) and Chinese (`MDRID291602`) archives.

Blockquotes below transcribe short, original change descriptions. English translations and summaries are labeled separately. These are the release benefits, not the installation instructions or license agreements. Dates are identified by region; a Japanese release date is not assumed to be the worldwide release date.

## 2.0.0

**Japan: October 4, 2018.** Sony's [dated announcement](https://www.sony.jp/headphone/info2/20180925.html) gives this change:

> Google アシスタント のためにヘッドホンを最適化する(Google アシスタント に対応)

**English translation:** Optimizes the headphones for Google Assistant (adds Google Assistant support).

The announcement is dated September 25, but specifically schedules the WH-1000XM3 update for **October 4**. Sony's [update index](https://www.sony.jp/headphone/update/xml/update.xml) identifies it as 2.0.0, corroborated by the [original installation page](https://www.sony.jp/headphone/update/20180925_WH-1000XM3_android.html).

**International:** Sony's [current international changelog](https://www.sony.com/electronics/support/downloads/00016733) retains Google Assistant optimization among the earlier improvements. The 2.0.0 attribution above comes from the Japanese history; an original international 2.0.0 release-note page was not recovered. Its exact English wording and international release date therefore remain unverified.

**Archive:** International binary present; Japanese binary missing. No Chinese 2.0.0 package is identified in our archive or checked Sony metadata.

## 4.1.1

**Japan: January 17, 2019.** Sony's [dated announcement](https://www.sony.jp/headphone/info2/20190117.html) lists:

> [1] Amazon Alexaに対応
>
> [2]音声ガイダンスの言語の変更が可能（WH-1000XM3のみ）

**English translation:** Adds Amazon Alexa support and the ability to change the voice-guidance language on WH-1000XM3.

Sony's [versioned installation page](https://www.sony.jp/headphone/update/20190117_WH-1000XM3_android.html) confirms 4.1.1. For international models, Sony's [Alexa guide](https://www.sony.com/electronics/support/articles/00225624) specifies firmware 4.1.1 or later. The [international cumulative changelog](https://www.sony.com/electronics/support/downloads/00016733) also records Alexa and selectable voice-guidance languages, with Headphones Connect 4.1.0 or later required on XM3. That page is corroboration, not an original international 4.1.1 transcription.

**Archive:** International and Japanese binaries present. China has a separately numbered 4.1.3 release.

## 4.1.3 — China

**Original WH-1000XM3 release notes and release date not recovered.** The [Chinese 4.1.3 binary](https://info.update.sony.net/HP001/MDRID291602/contents/0001/HDX-2916_V0413_CN.bin) is archived, but its availability does not establish its change list.

Sony's surviving [Chinese 4.5.2 page](https://service.sony.com.cn/download/firm/00002323.html) groups Tencent Xiaowei support, a touch-panel enable/disable setting, voice-guidance language selection and other improvements under earlier releases. It does not assign those items to individual versions.

A separate [Sony 4.1.3 notice dated January 31, 2019](https://service.sony.com.cn/download/firm/00002665.html) covers **WI-1000X and WH-1000XM2**, not WH-1000XM3. Its Xiaowei change and date are therefore not copied into this XM3 release entry.

## 4.2.2

**Japan: October 30, 2019.** Sony's [dated announcement](https://www.sony.jp/headphone/info2/20191030.html) lists:

> タッチセンサーコントロールパネル機能の有効／無効を切り替える機能を追加しました。

**English translation:** Adds a setting to enable or disable the touch-sensor control panel.

The [versioned installation page](https://www.sony.jp/headphone/update/20191030_WH-1000XM3_android.html) confirms 4.2.2. Sony's [international cumulative changelog](https://www.sony.com/electronics/support/downloads/00016733) corroborates the touch-panel setting and specifies Headphones Connect 6.0.0 or later. The original international 4.2.2 wording was not independently recovered.

**China:** Original 4.2.2 notes and release date remain unverified. The [Chinese support URL](https://service.sony.com.cn/download/firm/00002323.html) still mentions 4.2.2 in its title/breadcrumb, but its actual release text is now for 4.5.2. Its cumulative list cannot establish which changes were new in Chinese 4.2.2.

**Archive:** International, Japanese and Chinese binaries present.

## 4.5.2

**International: May 28, 2020.** Sony's [release page](https://www.sony.com/electronics/support/downloads/00016733) lists these new benefits:

> Enhances the security features of the system software
>
> Improves general performance of the headphones

**Japan: May 28, 2020**, according to Sony's [update index](https://www.sony.jp/headphone/update/xml/update.xml). The [Japanese package's original update notice](https://info.update.sony.net/HP001/MDRID291601/contents/0005/WH-1000XM3_NoG_v4.5.2.xml), in its `Japan` locale, says:

> [1] 本体ソフトウェアのセキュリティを強化しました。
>
> [2] その他の機能を改善しました。

**English translation:** Strengthens system-software security and improves other functions.

**China: May 28, 2020.** Sony's [Chinese release page](https://service.sony.com.cn/download/firm/00002323.html) says:

> 增强系统软件的安全功能.
>
> 改善其他功能.

**English translation:** Enhances system-software security features and improves other functions. The [Chinese package's update notice](https://info.update.sony.net/HP001/MDRID291602/contents/0003/WH-1000XM3_NoG_v4.5.2.xml) independently gives the same two changes in its English locale.

The earlier assistant, language and touch-panel features on these pages are cumulative benefits, not newly introduced 4.5.2 features. These notes do not identify particular security vulnerabilities or specify which other functions changed.

**Archive:** International, Japanese and Chinese binaries present.

## 1.0.8 and remaining gaps

No original 1.0.8 release notes or firmware package were located. Sony's update metadata recognizes it as an earlier installed version; that is not a changelog. The oldest WH-1000XM3 update in the checked [Japanese history](https://www.sony.jp/headphone/update/xml/update.xml) is 2.0.0.

The unresolved transcription gaps are the original international wording for 2.0.0/4.1.1/4.2.2 and the original Chinese 4.1.3/4.2.2 notes. Japanese release history and later cumulative lists are explicitly identified above rather than presented as those missing originals. None of the verified change descriptions above explicitly announces an ANC tuning change.

For package availability, filenames and checksums, see the [international archive](xm3/README.md) and [regional archive](xm3-regional/README.md).
