#!/bin/sh -x

BRANCH=paleolithic-01
PWD=`pwd`
STATE=$PWD/state
if [ ! -e ./lib/config.ml ]; then
  cp ./lib/config.ml.in ./lib/config.ml
fi
if [ ! -e $STATE ]; then
  mkdir $STATE
  cd $STATE
  git clone -b $BRANCH git@github.com:ocamlot/ocamlot-state.git .
  git config --local --add user.name ocamlot
  git config --local --add user.email dwws2@cam.ac.uk
  cd $PWD
fi
