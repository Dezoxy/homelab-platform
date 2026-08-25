terraform {
  cloud {
    organization = "toomhorvath"

    workspaces {
      name = "01-tailscale-lxc"
    }
  }
}
