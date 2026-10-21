# Third-party components

- [AMSMB2 4.0.3](https://github.com/amosavian/AMSMB2/tree/4.0.3), by amosavian and contributors. Distributed under LGPL-2.1 due to libsmb2; linked as the dynamic Swift Package product. See [upstream license](https://github.com/amosavian/AMSMB2/blob/4.0.3/LICENSE).
- [libsmb2](https://github.com/sahlberg/libsmb2), included as a submodule of the pinned AMSMB2 release. LGPL-2.1; exact revision is defined by that release.

Xcode resolves the package when building. The upstream LGPL-2.1 text is included in `Lightbox/Resources/LGPL-2.1.txt` and bundled with the app. Attribution and source locations are included in `Lightbox/Resources/ThirdPartyNotices.txt`. The library is used without modifications. Rebuild instructions are in README.md.
