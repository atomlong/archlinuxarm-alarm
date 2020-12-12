#!/bin/bash

set -e

# AppVeyor and Drone Continuous Integration for MSYS2
# Author: Renato Silva <br.renatosilva@gmail.com>
# Author: Qian Hong <fracting@gmail.com>

# Configure
source "$(readlink -f $(dirname $0))/ci-library.sh"

[ -z "${PACMAN_ARCH}" ] && export PACMAN_ARCH=$(sed -nr 's|^CARCH=\"(\w+).*|\1|p' /etc/makepkg.conf)
[ -z "${DEPLOY_PATH}" ] && { echo "Environment variable 'DEPLOY_PATH' is required."; exit 1; }
[[ ${DEPLOY_PATH} =~ '$' ]] && eval export DEPLOY_PATH=${DEPLOY_PATH}
[ -z "${RCLONE_CONF}" ] && { echo "Environment variable 'RCLONE_CONF' is required."; exit 1; }
[ -z "${PGP_KEY_PASSWD}" ] && { echo "Environment variable 'PGP_KEY_PASSWD' is required."; exit 1; }
[ -z "${PGP_KEY}" ] && { echo "Environment variable 'PGP_KEY' is required."; exit 1; }
[ -z "${PACMAN_REPO}" ] && { echo "Environment variable 'PACMAN_REPO' is required."; exit 1; }
[ -z "${CUSTOM_REPOS}" ] || add_custom_repos
ARTIFACTS_PATH=${PWD}/artifacts/${PACMAN_ARCH}

pacman --sync --refresh --sysupgrade --needed --noconfirm --disable-download-timeout base-devel rclone expect git

git_config user.email 'ci@alarm.org'
git_config user.name  'ALARM Continuous Integration'

grep -Pq "^alarm:" /etc/group || groupadd "alarm"
grep -Pq "^alarm:" /etc/passwd || useradd -m "alarm" -s "/bin/bash" -g "alarm"
chown -R alarm:alarm ${GITHUB_WORKSPACE}
mkdir -pv ${HOME}/.config/rclone
printf "${RCLONE_CONF}" > ${HOME}/.config/rclone/rclone.conf
import_pgp_seckey

# Detect
#list_commits  || failure 'Could not detect added commits'
list_packages || failure 'Could not detect changed files'
#message 'Processing changes' "${commits[@]}"
test -z "${packages}" && success 'No changes in package recipes'
#define_build_order || failure 'Could not determine build order'

# Build
message 'Building packages' "${packages[@]}"
for package in "${packages[@]}"; do
execute 'Building packages' build_package
execute "Generating package signature" create_package_signature
execute "Deploying artifacts" deploy_artifacts
done
success 'All packages built successfully'
