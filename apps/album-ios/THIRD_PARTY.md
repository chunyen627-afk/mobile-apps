# Third-party components

- [MobileVLCKit 3.7.3](https://github.com/videolan/vlckit/tree/319ed2c0), VideoLAN and contributors, LGPL-2.1-or-later, unmodified official binary with libVLC revision `79128878`. Download: https://download.videolan.org/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz . SHA256: `0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9`. `scripts/fetch_vlc.sh` verifies the archive. Sources/build scripts: https://github.com/videolan/vlckit/tree/319ed2c0 ; libVLC: https://code.videolan.org/videolan/vlc/-/tree/79128878 . The app source is available for rebuilding/relinking with a modified library. Binary dependencies are not committed to this repository.

- [AMSMB2 4.0.3](https://github.com/amosavian/AMSMB2/tree/4.0.3), by amosavian and contributors. Distributed under LGPL-2.1 due to libsmb2; linked as the dynamic Swift Package product. See [upstream license](https://github.com/amosavian/AMSMB2/blob/4.0.3/LICENSE).
- [libsmb2](https://github.com/sahlberg/libsmb2), included as a submodule of the pinned AMSMB2 release. LGPL-2.1; exact revision is defined by that release.

Xcode resolves the package when building. The upstream LGPL-2.1 text is included in `Lightbox/Resources/LGPL-2.1.txt` and bundled with the app. Attribution and source locations are included in `Lightbox/Resources/ThirdPartyNotices.txt`. The library is used without modifications. Rebuild instructions are in README.md.
