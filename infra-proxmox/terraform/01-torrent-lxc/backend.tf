terraform {
  cloud {
    organization = "toomhorvath"

    workspaces {
      name = "01-torrent-lxc"
    }
  }
}
