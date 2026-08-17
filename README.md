# Rebuilt Gentoo 🐧

A modern, curated Gentoo-based distribution project.

## Goals

- Stay close to upstream Gentoo and Portage
- Provide a polished, reproducible ISO experience
- Ship sensible modern defaults
- Provide Rebuilt Gentoo branding and artwork
- Keep custom changes separate from the upstream Gentoo tree

## Base

- Gentoo Linux
- Portage / `emerge`
- OpenRC
- x86_64 initially
- KDE Plasma as the planned default desktop

## Repository layout

- `gentoo/` — synchronized upstream Gentoo package tree
- `branding/` — Rebuilt Gentoo branding installed into images/systems
- `profiles/` — Rebuilt Gentoo profile customizations
- `overlay/` — Rebuilt Gentoo package overlay
- `scripts/` — maintenance and build scripts
- `.github/workflows/` — automated upstream synchronization/build jobs

## Upstream

Rebuilt Gentoo tracks the official Gentoo repository. Upstream files retain their original licenses and copyright notices. Rebuilt Gentoo's original files are licensed separately where indicated.

## Status

🚧 Early development.
