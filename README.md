# Rebuilt Gentoo

A modern Gentoo-based distribution project.

## Upstream

Rebuilt Gentoo uses the official Gentoo Portage repository as its upstream package tree. The project keeps its own overlay/configuration separate so upstream updates can be synchronized without manually copying individual ebuilds.

Upstream: https://github.com/gentoo/gentoo

## Repository layout

- `profiles/` — Rebuilt Gentoo profiles and configuration
- `overlay/` — Rebuilt Gentoo package overlay
- `scripts/` — maintenance and build scripts
- `.github/workflows/` — automated upstream synchronization/build jobs

## License

Gentoo packages and files synchronized from upstream retain their original licenses and copyright notices. Rebuilt Gentoo's original files are licensed separately where indicated.
