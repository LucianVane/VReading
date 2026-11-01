# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- English UI (now the default) with Simplified Chinese localization via String Catalogs, plus an in-app language switch (Settings → App Language).
- English and Chinese versions of the Wi-Fi transfer web page.
- Wiktionary web dictionary, the default for non-Chinese UI languages.
- Screenshots and a user guide in the README.
- Release workflow: pushing a `v*` tag builds an unsigned IPA and publishes it to GitHub Releases.

### Changed
- AI prompts are written in English and state the output language explicitly; the default AI tutor prompts follow the UI language.
- The default translation target follows the device language instead of always being Chinese.
- Discover opens on English by default.
- Books flagged as adult content are labeled "18+" and hidden by default (toggle on the Discover tab).
- Open-sourced as **VReading** (formerly an internal project).
- API keys are no longer embedded; they are configured in the app or via `Local.xcconfig`.
- The copyrighted English–Chinese dictionary is no longer bundled.

## [1.0.0]

- Initial feature set: EPUB/PDF/TXT reader, MDict dictionaries, translation and AI services, graded vocabulary, SM-2 review with Anki export, OPDS/WebDAV sources, podcasts with synced subtitles, Wi-Fi transfer.
