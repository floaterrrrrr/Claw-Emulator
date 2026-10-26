# Claw listing handoff

The copy in `app-store-metadata.json` is ready to transfer into the existing English (U.S.) version. The app name, subtitle, keywords, promotional text and description respect Apple's field limits. No account/login is required. Support contact: feedback@salamlabs.io. Private review-contact name and phone remain in App Store Connect, not in public source.

## Public links

- Support: https://claw-emulator.sunsetpine6.chatgpt.site/support/
- Privacy: https://claw-emulator.sunsetpine6.chatgpt.site/privacy/
- Source and releases: https://github.com/floaterrrrrr/Claw-Emulator

Verify these are deployed and anonymously accessible before entering them in App Store Connect. Publication evidence is recorded separately; an expected URL alone is not evidence.

## Privacy questionnaire facts

Claw has no account, ads, analytics SDK, developer telemetry, remote cover catalogue, or developer-operated game upload/backup service. Imported files, preferences, save data, console keys and launch diagnostics stay in local app storage. iOS backup, chosen share destinations, optional camera/microphone input and networking requested by imported software are described in the policy. Support email is voluntary and used to reply.

Apple defines collection as off-device transmission accessible to the developer or partners beyond servicing a request in real time. Data processed entirely on device is not collected for the nutrition label. Optional support correspondence can be omitted only if it meets **all** Apple's optional-disclosure criteria. The account owner must confirm actual support practices and the exact submitted binary before saving “Data Not Collected”; this document does not claim a questionnaire was submitted. No tracking is implemented by Claw.

## Age rating, rights and availability

Answer Apple's current age-rating questionnaire for the features actually offered in Claw. Claw imports user-supplied software; it does not offer a hosted catalogue, chat, ads, gambling service, or account/social system. Do not select a rating merely from the absence of bundled games or imply that arbitrary imported games are all suitable for children. Let the questionnaire calculate its rating, then apply any appropriate higher override.

The owner must confirm content rights for the app icon, skins and each screenshot. Console names identify compatibility; the in-app disclaimer states no Nintendo affiliation and attributes trademarks. A disclaimer does not grant rights to third-party games, artwork or skins. Use genuine screenshots of the final build and content you can display. The separate `output/` marketing drafts are not automatically approved as store screenshots or proof of gameplay.

Pricing, territories, tax/business agreements and trader information require the account owner's actual choices; they have not been changed by repository edits.

## Reviewer attachments and screenshots

`Distribution/reviewer-test.md` supplies steps and CC0 fixture licensing. Generate the original fixtures with `Tests/make-retro-fixtures.py`; test them in the exact signed build before attaching them. Include version/build, source commit, test device/iOS, import instructions, expected screen/input behavior and observed results. Provide a compatible lawfully redistributable 3DS example if used to demonstrate 3DS support; no such device test has been recorded here.

Capture real library, controls/settings, portrait and landscape screens from the candidate. Apple requires screenshots to show the app in use; do not pass demo composites or mock-core gameplay off as the shipping app. Upload the dimensions/device classes currently required by App Store Connect. Select manual release if that is still the owner's preference.

## Candidate status

Build 115 resolved the immediate 3DS launch crash in the owner's iPhone 17 test. The next signed candidate restores source-built FFmpeg and uses the Claw-branded canonical project/native bridge. Its final device check is pending. Keep App Review submission untouched until that candidate and the listing assets are complete.

References checked October 25, 2026:
- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
