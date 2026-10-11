# Releasing

Releases are signed with a Developer ID, notarized, and published on GitHub as `Tiller-<version>.dmg` for installing and `Tiller-<version>.zip` for [Sparkle](https://sparkle-project.org), which updates installed copies from the appcast at `https://sorrycc.github.io/Tiller/appcast.xml`. A version with a pre-release part, such as `0.2.0-beta.1`, is a beta: a GitHub pre-release that only Tillers with Settings > General > Include beta versions turned on update to.

To release, run `scripts/bump.sh <version>`, such as `scripts/bump.sh 0.2.0-beta.1`, or give it `patch`, `minor`, `major` or `beta` to work the version out from the current one. It sets the version in `Cargo.toml` and `Cargo.lock`, commits that as `v<version>`, tags the commit, and after asking pushes `main` and the tag, which has the Release workflow build and publish it. Before a release, write its notes under `## Unreleased` in `CHANGELOG.md` and commit them: `bump.sh` renames that section to `## <version>` in the version commit and refuses to bump without notes, and the GitHub release and the update window show them. A beta leaves `CHANGELOG.md` alone and shows whatever `## Unreleased` holds, or the generated list of pull requests when it is empty. To build on your own Mac instead, answer no, push `main`, and run `scripts/release.sh` on a Mac set up as below. `scripts/fetch-cef.sh` downloads CEF and the codecs build for the workflow, checking the codecs archive against a pinned hash.

One-time setup:

1. In the Apple Developer site, create a **Developer ID Application** certificate and install it in your login keychain. Export it from Keychain Access as a `.p12` with a password.
2. At [account.apple.com](https://account.apple.com), create an app-specific password for notarization.
3. Make Sparkle's update signing key with `app/.build/artifacts/sparkle/Sparkle/bin/generate_keys` (after a build), which keeps it in your keychain and prints the public key. Put that in `scripts/sparkle-public-key` and commit it. `generate_keys -x sparkle-private-key` exports the private key for the workflow; delete the file afterwards.
4. In the repository's Settings > Secrets and variables > Actions, add:

   | Secret | Value |
   |---|---|
   | `MACOS_CERTIFICATE_P12` | `base64 -i certificate.p12` |
   | `MACOS_CERTIFICATE_PASSWORD` | the `.p12`'s password |
   | `APPLE_ID` | your Apple Account email |
   | `APPLE_APP_SPECIFIC_PASSWORD` | the app-specific password |
   | `APPLE_TEAM_ID` | your team ID |
   | `SPARKLE_PRIVATE_KEY` | the exported private key |

5. After the first release creates the `gh-pages` branch, turn on GitHub Pages for it in Settings > Pages.
6. To release from your Mac too, store notarization credentials once: `xcrun notarytool store-credentials tiller-notary --apple-id <email> --team-id <team> --password <app-specific password>`.
