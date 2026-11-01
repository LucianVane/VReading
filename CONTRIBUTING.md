# Contributing to VReading

Thanks for your interest! Bug reports, features, translations and docs are all welcome.

## Getting set up

1. Fork and clone the repo, then `open VReading.xcodeproj`.
2. (Device builds only) `cp Local.xcconfig.example Local.xcconfig` and set your team / bundle ID.
3. Run the **VReading** scheme on an iOS 18+ simulator.

There are no package dependencies. Please keep it that way unless a dependency brings substantial value — discuss it in an issue first.

## Workflow

1. Open an issue for anything non-trivial before you start, so we can agree on the approach.
2. Create a branch: `feat/short-name`, `fix/short-name`, `docs/...`.
3. Keep PRs focused; one logical change per PR.
4. Make sure the project builds with no new warnings:
   ```bash
   xcodebuild -project VReading.xcodeproj -scheme VReading \
     -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
   ```
5. Fill in the pull request template, including screenshots for UI changes.

We use [Conventional Commits](https://www.conventionalcommits.org/) style messages, e.g. `fix(reader): keep position after font change`.

## Code style

- Swift 5, SwiftUI first; UIKit only where SwiftUI falls short.
- 4-space indentation (see `.editorconfig`).
- **All user-facing text is written in English in code** and localized through `VReading/Resources/Localizable.xcstrings`.
  - SwiftUI literals (`Text("…")`, `Button("…")`, `.navigationTitle("…")`) are localized automatically.
  - Anything typed as `String` (toasts, errors, enum titles, helper parameters) must use `String(localized: "…")`.
  - Building in Xcode adds new keys to the catalog. Please add the Simplified Chinese translation too, or mention in the PR that it is missing.
- Prompts sent to AI models are written in English and state the output language explicitly; they are not localized.
- Code comments may be in English or Chinese; English is preferred for new code.

## Secrets and data

- **Never commit API keys.** Put personal values in `Local.xcconfig` (git-ignored).
- Only add bundled data (dictionaries, word lists, books, fonts, images) whose license allows redistribution, and add an entry to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Do not add sources that link to pirated content.

## Translations

Want VReading in your language? Add it to `Localizable.xcstrings` and `InfoPlist.xcstrings` in Xcode, add a `lang.<code>.js` for the Wi-Fi page if you can, and add the language to `AppLanguage` in `Core/AppLanguage.swift`. Open an issue titled `i18n: <language>` if you'd like help.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
