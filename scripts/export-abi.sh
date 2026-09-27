#!/bin/sh
set -eu
mkdir -p docs/abi
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/ArbiterEscrow.sol:ArbiterEscrow abi --json > docs/abi/ArbiterEscrow.json
