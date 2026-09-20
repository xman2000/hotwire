#!/usr/bin/env bash
#
# Copy this file to secrets.sh in the same folder and set a real RCON password:
#
#   cp secrets.example.sh secrets.sh
#   nano secrets.sh
#   chmod 600 secrets.sh
#
# secrets.sh is sourced by the launcher and is the ONE place the RCON password
# lives. Never commit it, and never put it on a command line. A good one:
#
#   RCON_PASSWORD="$(openssl rand -base64 24)"
#
RCON_PASSWORD="change_me"
