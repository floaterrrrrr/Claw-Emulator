# Claw source, notices and build provenance

The release source repository is https://github.com/floaterrrrrr/Claw-Emulator. It is private at the owner's request. Do not create a public repository or change repository visibility without the owner's explicit approval. Source, dependency pins, local patches and build recipes are retained for the release; publication remains the owner's separate action.

## Dependency evidence

| Component | Evidence and distribution materials |
| --- | --- |
| Claw and Cytrus/Azahar/Citra | App and modified core sources are included with GPL notices. Vendored SharedDependencies and Zstandard source, Swift package revisions, and local patches are retained. |
| Source-built FFmpeg | n8.1.2 revision `38b88335f99e76ed89ff3c93f877fdefce736c13`, archive SHA-256 `2ae7e42343cfffb811d15cfe98b6d005f082595fcdf034d30a4ff90cfed9f9c6`. The source rebuild script, configure flags and seven library build records are included. Supplied Cloud logs at `9cd3711` matched all seven archived device UUIDs to the source build. That proves build identity, not device gameplay. |
| MoltenVK | Both bundled 1.4.3 slices match Folium commit `3b23e1d41247f7b98a7f01ad6ade02bd28cc3c29` exactly by Git blob and size, with independent SHA-256 values. `moltenvk-provenance.json` records both paths/hashes. Apache 2.0 license texts and MoltenVK/SPIRV-Cross attribution are bundled in Settings and retained in `Distribution/licenses/`. Claw has not modified these binaries. Folium's exact upstream compiler/source recipe is unknown; binary reproduction is not claimed. The staged upstream 1.4.2 candidate is not used. |
| Boost | The device iostreams binary matches pinned public Folium and identifies Boost 1.89.0. Matching headers and source are checksum-pinned. Header-only Boost.ICL uses the pinned 1.92.0 lookup fix in `header-sources.json` for libc++ 22 compatibility; compiled Boost libraries remain 1.89.0. The Boost Software License notice is bundled; exact reproduction of the prebuilt compiler output is not claimed. |
| Rebuilt native dependencies and retro cores | Exact revisions, archive checksums, patches and build scripts are in `dependency-sources.json`, `ThirdParty/RetroCores/sources.lock.json` and the scripts. |
| FLAC and Ogg | Swift binary package versions/checksums are pinned and BSD notices are included. |
| System archive replacements and fonts | Generator sources and embedded commits are recorded in `bundled-data-sources.json`; Montserrat OFL and GNU Unifont GPL/font-exception notices are bundled. |

## Public source snapshot

`Scripts/export-public-source.py` exports an exact committed tree without private Git history, local credentials, account configuration, developer logs or user output. It excludes the unverified legacy FFmpeg prebuilts and private-repository CI workflows. Public build instructions recreate FFmpeg from the pinned source; the source-materials ZIP additionally contains all 28 checksum-verified upstream archives. `SOURCE_SNAPSHOT.json` records the development commit, exclusions and file hashes. The original development repository's history remains private.

Use a stable source release/tag matching the binary's development commit and retain its source-materials package. Publish the matching source again for later distributed revisions. In a public source checkout, use `CLAW_FFMPEG_MODE=source` for Cloud; legacy baseline artifacts are deliberately absent. The repository retains the complete emulator source and local modifications rather than a link-only offer.

## Device regression and Build 115 confirmation

Builds 110–114 archived and distributed but crashed on 3DS launch. The matching Build 114 crash/archive pinpointed a Boost.ICL interval-lookup assertion in rasterizer page accounting. Fix commit `b702d36` includes the pinned header-only compatibility update and page-range hardening; host regressions pass with assertions enabled and its Xcode Cloud workflow succeeded. On October 25, 2026, the owner confirmed **Build 115 launches 3DS games successfully on iPhone 17**, resolving the reported immediate launch failure in that device test. FFmpeg's seven runtime probes had already passed. The release candidate now defaults to source-built FFmpeg with that same crash fix. The exact Build 102 baseline remains available only through an explicit diagnostic override and is excluded from the public source snapshot. See `build-110-launch-investigation.md`.

Confirm the new source-built signed candidate on device before selecting it for App Store review. The final archive must retain licenses/privacy manifests, pass signatures and dependency checks, match its recorded source/build number, and be tested for imports, 3DS rendering, audio, saves/loads, controls, rotation, background/resume and export. Record results against the actual build and device.

## Listing and account handoff

See `listing-handoff.md` for copy, public URLs, privacy facts, screenshots, reviewer fixtures and account choices. The owner completed export compliance; `ITSAppUsesNonExemptEncryption=false` preserves that declaration. No export-compliance ticket is pending. Age rating, content rights, privacy answers, pricing and availability must accurately reflect the final app and the owner's choices. The immediate 3DS launch regression is resolved in the Build 115 owner test; public submission still requires the remaining release and account/listing checks. Artwork work is deferred at the owner's request.
