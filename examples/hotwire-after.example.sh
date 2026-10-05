#!/usr/bin/env bash
# ==[ H O T W I R E ]===================================================
#  hotwire-after.sh -- your own commands, run after an update.
#
#  To use it, copy this file to hotwire-after.sh beside hotwire.sh.
#  It runs from the server's folder after Rust and Oxide are updated and
#  before the server starts. If it fails, the launcher logs that and
#  starts the server anyway; "./hotwire.sh check" never runs it.
#
#  Hotwire never creates or changes this file. What is in it is yours.
# ======================================================================

# Examples. Remove the # to use one.

# Keep a note of when each update happened:
#date >> updates.txt

# Put back a file an update replaces, from a copy of your own:
#cp -a ~/my-files/some-file.cfg server/my_server/cfg/
