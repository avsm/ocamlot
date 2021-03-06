# OCamlot : OCaml Online Testing

## Usage

### Server

 - `./ocamlot_cmd.native serve`

### Worker

 - `../ocamlot/install_ocaml.sh <NICKNAME> <PATH_TO_OCAML_SRC>`
 - `../ocamlot/ocamlot_cmd.native work <URL>`

## Requirements

System libraries:

 - libssl

Pinned Dev packages:

 - avsm/ocaml-github@master
 - avsm/ocaml-cohttp@master
 - mirage/ocaml-cow@master

These packages are installable with `./setup_deps.sh`

OPAM Packages:

 - oasis-mirage
 - cohttp
 - cryptokit
 - github
 - lwt
 - cmdliner
 - re
 - sexplib
 - uri
 - cow

These packages are installable with `./install_deps.sh`

## Build

 - `./setup_deps.sh`
 - `./install_deps.sh`
 - `oasis setup`
 - `make`
