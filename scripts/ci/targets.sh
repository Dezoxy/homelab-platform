#!/usr/bin/env bash
# Canonical ordered list of all deployment targets.
# Source this file instead of hardcoding targets in multiple places.
# Adding a new host: add it here and to the inputs block of deploy.yml.
# shellcheck disable=SC2034  # used by scripts that source this file
ALL_TARGETS=(
  "01-edge-lxc"
  "01-dns-lxc"
  "01-reverse-proxy-lxc"
  "01-torrent-lxc"
  "01-observability-lxc"
  "01-backup-lxc"
  "01-tailscale-lxc"
  "01-media-vm"
  "01-myapps-vm"
  "01-unifi-vm"
)
