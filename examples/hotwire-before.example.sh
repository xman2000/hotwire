#!/usr/bin/env bash
# ==[ H O T W I R E ]===================================================
#  hotwire-before.sh -- your own commands, run before every start.
#
#  To use it, copy this file to hotwire-before.sh beside hotwire.sh.
#  It runs from the server's folder, before any update. If it fails, the
#  launcher logs that and starts the server anyway; "./hotwire.sh check"
#  never runs it. Keep it quick: the server waits for it.
#
#  Hotwire never creates or changes this file. What is in it is yours.
# ======================================================================

# Examples. Remove the # to use one.

# Copy the plugin configs somewhere safe:
#cp -a oxide/config ~/rust-config-copy/

# Tell a Discord channel the server is starting (a webhook URL of your own):
#curl -s -H 'Content-Type: application/json' -d '{"content":"Server starting"}' https://discord.com/api/webhooks/...
