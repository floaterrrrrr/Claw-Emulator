# Claw release validation — October 25, 2026

**Build 102 is validated by Apple for TestFlight. It is not ready for public App Store submission.** The handoff cleanup has been integrated into the current UI source; it is not present in build 102. Local build defaults are now 103. Xcode Cloud supplies its own next build number.

## Evidence from the actual candidate

App Store Connect → TestFlight → 1.0.0 (102) → Build Metadata reports **Binary State: Validated**, arm64, iPhone, iOS 17.0, and included symbols. TestFlight lists the build as **Testing**. The matching Xcode Cloud archive and internal/external distribution actions succeeded, with 110 warnings and no reported build errors, static-analysis issues or test failures. These counters do not represent a complete device/UI test run.

- Source commit: `14b50a2a939c65113b7196d1755f2399977248fd`.
- Bundle ID: `com.salamlabs.claw`; version 1.0.0, build 102.
- Downloaded archive and App Store IPA both identify this same source and build.
- App uses Xcode 27.1 and iOS 27.1 SDK. All 15 Mach-O binaries are arm64 iOS device binaries with minimum deployment versions no higher than iOS 17.0.
- App, three retro cores, FLAC, OpenSSL and Ogg dSYM UUIDs match their archive binaries. MoltenVK and seven FFmpeg framework dSYMs are absent; they are not represented as verified symbols.
- The exported provisioning profile disables `get-task-allow`. This is metadata inspection, not cryptographic signature verification.
- Cloud host logs record passing compiler, audio, archive import, control layout, library, skin, graphics, thermal and save/runtime regression checks. UI tests and gameplay on supported phones still require execution.
- Build 102 omits the disk-space required-reason declaration despite `statvfs` in the archive importer. The release manifest now declares `E174.1` for its storage check before extraction and `3B52.1` for metadata of files selected through the document picker; these fixes require the new build. These uses match [Apple's documented reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- Warnings include upstream Doxygen comments, libslirp macro/precedence warnings and other native diagnostics. They have been recorded, not suppressed or represented as resolved.

Hashes, binary UUIDs and deployment versions are recorded in `build-102-validation.json`. Original archive, IPA, logs and detailed local reports remain outside Git under `.build-dependencies/release-evidence` or Downloads. Keep provisioning/account material and full logs private.

## Changes prepared after build 102

The release tree removes bundled console/HTTP credentials, the game-specific cheat sheet, remote cover-art downloads and old patch files containing removed code. It restores the Cytrus license and adds dependency/font/source notices, source pins, reviewer instructions and a generic imported-cheat parser. The earlier unverified encryption declaration was removed during cleanup; the owner has since completed the App Store Connect declaration and instructed that `ITSAppUsesNonExemptEncryption=false` be committed for future builds. The recent UI refinements are retained. The tracked-tree audit checks known removed files, while native parser, asset/project and Swift syntax checks validate the integration within this Windows environment. A new iOS build is still required to include the latest source changes.

Local verification also passed eight artifact/manifest tests and native input/pause/shutdown tests. The native performance suite could not finish on Windows because its filesystem symlink operation is unsupported; rerun it on macOS. The download unit suite did not complete in this host session; the real download path did verify all 27 archives. No local iOS compile, signature verification or device test is claimed.

## Remaining gates

| Gate | Evidence needed |
| --- | --- |
| Source/binary correspondence | FFmpeg source builds and all seven archived device UUIDs were verified from Cloud logs for `9cd3711`; retain that evidence and finish device compatibility tests. Resolve MoltenVK 1.4.3 provenance or build/test a documented replacement, including simulator support. Candidate source pins alone do not prove binary correspondence. |
| Public source and notices | Publish a clean snapshot of the final source and required upstream source/build materials, with a stable release identifier. Keep the original development Git history private. Review GPL obligations and distribution terms before declaring clearance. |
| Privacy and support | Publish accessible HTTPS policy/support pages. The source removes remote covers; build 102 still includes them and does not match the new policy. The Apple page has no privacy-policy URL or completed disclosure. |
| Apple account fields | Complete content rights, age rating and privacy with the responsible account roles. The owner reports export compliance completed and builds 102/103 active in TestFlight. Confirm the next build inherits the committed declaration. |
| Listing and reviewer kit | Replace the outdated 3DS-only description, fill support/copyright/reviewer fields and upload permitted screenshots. Attach a licensed test game and results from the final signed build. The App Store version is still “Prepare for Submission,” with no selected build shown. |
| Final validation | Rebuild the integrated source, verify exported signatures on a Mac, test on supported iPhones, then select that exact build for review. TestFlight validation does not establish licensing, gameplay quality or App Review acceptance. |

## Run the remaining technical checks on the Mac

Use the release branch from the private repository. For a completed archive and its exported IPA:

```sh
bash Scripts/validate-release-on-mac.sh \
  '/path/to/Claw.xcarchive' '/path/to/Claw.ipa' BUILD FULL_SOURCE_COMMIT
```

The command writes evidence under `Validation/AppStore/build-BUILD`, checks source/legal resources, Mach-O deployment/UUIDs and the exported app's signatures/entitlements. Historical build 102 will intentionally fail the new cheat-sheet gate and current legal-resource comparison; its other results remain available. It does not upload, submit or accept agreements.

Encryption declaration: the owner reported completing App Store Connect's standard-encryption and Category 5, Part 2 Note 4 exclusion questions on October 25, 2026, with builds 102/103 active in TestFlight. At the owner's explicit instruction, `App/Info.plist` now declares `ITSAppUsesNonExemptEncryption=false`. Local and Cloud archive metadata preserve the committed Boolean when `CLAW_USES_NON_EXEMPT_ENCRYPTION` is empty. No environment override or approval code is needed for this declaration. An explicit `true` override would supersede it and should be used only for a changed distribution decision. See [Apple's build-compliance instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds).

The [source-based encryption assessment](encryption-assessment.md) retains the technical review at `9cd3711` and separately records the subsequent owner declaration. The [source evidence](encryption-source-evidence.json) preserves its original hashes and adds the owner-reported release decision. The remaining handoff actions are listed in [release-handoff.md](release-handoff.md); an Apple export-compliance ticket is not one of them.

Stage source-built replacements separately:

```sh
python3 Scripts/rebuild-ffmpeg-ios.py
python3 Scripts/stage-official-moltenvk.py
```

Do not substitute either staged binary before link, rendering/audio and device performance comparisons pass. Once the final source is clean and committed, `python3 Scripts/package-pinned-source.py --output build/claw-source-materials.zip` bundles the exact tree and 27 pinned upstream archives. The manifest remains explicitly incomplete while binary-source gates remain open.

References checked October 25, 2026: [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/), [SDK requirements](https://developer.apple.com/news/upcoming-requirements/), [Apple export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/), [FFmpeg licensing](https://www.ffmpeg.org/legal.html), [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html).
