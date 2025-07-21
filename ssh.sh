#!/bin/bash

# Usage: ./copy_ssh_key.sh <username> <host>

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <username> <host>"
  exit 1
fi

USERNAME="$1"
HOST="$2"

echo "Removing existing SSH key for $HOST from known_hosts..."
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$HOST"

echo "Copying SSH key to $USERNAME@$HOST..."
ssh-copy-id "$USERNAME@$HOST"
