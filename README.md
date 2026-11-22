# thingino-tools

Tools for cameras running [Thingino](https://github.com/themactep/thingino-firmware), each in its own folder, each built from upstream sources by its own `build.sh`. They run from RAM (`/tmp`) and write nothing to flash.

| Tool | For | Release tags |
|---|---|---|
| [wifi-kit](wifi-kit/) | Ingenic T31 (XBurst1, mipsel, uClibc): static `iw`, `tcpdump` and `iperf3`, and `wifi-watch.sh`, a link logger for the ATBM6031 uplink that drops to 13 Mbps ([issue 1915](https://github.com/themactep/thingino-firmware/issues/1915)) | `wifi-kit-*` |

## Conventions

- **One folder a tool,** with a `README.md` that says what it is for, how to install and use it, and what it was tested on, and a `build.sh` that builds it from nothing.
- **Sources from upstream,** each checked against a pinned sha256 in `build.sh`. The toolchain is Thingino's own release.
- **Binaries are release assets, not commits,** tagged `<tool>-<YYYY-MM-DD>`, with `SHA256SUMS` and the source of any LGPL library linked statically.

## Licence

The scripts and documents here are MIT (`LICENSE`). Third-party programs in a release keep their own licences, which ship inside that release.
