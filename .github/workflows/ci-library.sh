#!/bin/bash

# Continuous Integration Library for ArchLinuxARM
# Author: Renato Silva <br.renatosilva@gmail.com>
# Author: Qian Hong <fracting@gmail.com>

# Enable colors
normal=$(tput sgr0)
red=$(tput setaf 1)
green=$(tput setaf 2)
cyan=$(tput setaf 6)

# Basic status function
_status() {
    local type="${1}"
    local status="${package:+${package}: }${2}"
    local items=("${@:3}")
    case "${type}" in
        failure) local -n nameref_color='red';   title='[ALARM CI] FAILURE:' ;;
        success) local -n nameref_color='green'; title='[ALARM CI] SUCCESS:' ;;
        message) local -n nameref_color='cyan';  title='[ALARM CI]'
    esac
    printf "\n${nameref_color}${title}${normal} ${status}\n\n"
    printf "${items:+\t%s\n}" "${items:+${items[@]}}"
}

# Convert lines to array
_as_list() {
    local -n nameref_list="${1}"
    local filter="${2}"
    local strip="${3}"
    local lines="${4}"
    local result=1
    nameref_list=()
    while IFS= read -r line; do
        test -z "${line}" && continue
        result=0
        [[ "${line}" = ${filter} ]] && nameref_list+=("${line/${strip}/}")
    done <<< "${lines}"
    return "${result}"
}

# Changes since last build
_list_changes() {
    local list_name="${1}"
    local filter="${2}"
    local strip="${3}"
    local git_options=("${@:4}")
	local marker="build.marker"
    local branch_url="$(git remote get-url origin | sed 's/\.git$//')/tree/${CI_BRANCH}"
	local commit_sha
	
	rclone copy "${DEPLOY_PATH}/${marker}" . &>/dev/null && commit_sha=$(sed -rn "s|${branch_url}\s+([[:xdigit:]]+).*|\1|p" "${marker}")
	rm -f ${marker}
	[ -n "${commit_sha}" ] || commit_sha="HEAD^"
	
	_as_list "${list_name}" "${filter}" "${strip}" "$(git log "${git_options[@]}" ${commit_sha}.. | sort -u)"
}

# log git sha for the current build
_create_build_marker() {
	local branch_url="$(git remote get-url origin | sed 's/\.git$//')/tree/${CI_BRANCH}"
	local marker="build.marker"
	
	rclone copy "${DEPLOY_PATH}/${marker}" . &>/dev/null || touch "${marker}"
	(grep -q "${branch_url}" "${marker}") && \
	sed -i -r "s|(${branch_url}\\s*).*|\1${CI_COMMIT}|g" "${marker}" || \
	printf '%-80s%s\n' "${branch_url}" "${CI_COMMIT}" >> "${marker}"
	rclone move "${marker}" "${DEPLOY_PATH}"
}

# Get package information
_package_info() {
    local package="${1}"
    local properties=("${@:2}")
    for property in "${properties[@]}"; do
        local -n nameref_property="${property}"
        nameref_property=($(
            source "${package}/PKGBUILD"
            declare -n nameref_property="${property}"
            echo "${nameref_property[@]}"))
    done
}

# Package provides another
_package_provides() {
    local package="${1}"
    local another="${2}"
    local pkgname provides
    _package_info "${package}" pkgname provides
    for pkg_name in "${pkgname[@]}";  do [[ "${pkg_name}" = "${another}" ]] && return 0; done
    for provided in "${provides[@]}"; do [[ "${provided}" = "${another}" ]] && return 0; done
    return 1
}

# Add package to build after required dependencies
_build_add() {
    local package="${1}"
    local depends makedepends
    for sorted_package in "${sorted_packages[@]}"; do
        [[ "${sorted_package}" = "${package}" ]] && return 0
    done
    _package_info "${package}" depends makedepends
    for dependency in "${depends[@]}" "${makedepends[@]}"; do
        for unsorted_package in "${packages[@]}"; do
            [[ "${package}" = "${unsorted_package}" ]] && continue
            _package_provides "${unsorted_package}" "${dependency}" && _build_add "${unsorted_package}"
        done
    done
    sorted_packages+=("${package}")
}

# get last commit hash of one package
_last_package_hash()
{
local package="${1}"
local marker="build.marker"
rclone copy "${DEPLOY_PATH}/${marker}" . &>/dev/null && sed -rn "s|^\[([[:xdigit:]]+)\]${package}|\1|p" "${marker}"
rm -f ${hashfile}
return 0
}

# get current commit hash of one package
_now_package_hash()
{
local package="${1}"
git log --pretty=format:'%H' -1 ${package} 2>/dev/null
return 0
}

# record current commit hash of one package
_record_package_hash()
{
local package="${1}"
local marker="build.marker"
local commit_sha

commit_sha="$(_now_package_hash ${package})"
rclone copy "${DEPLOY_PATH}/${marker}" . &>/dev/null || touch "${marker}"
grep -Pq "\[[[:xdigit:]]+\]${package}" ${marker} && \
sed -i -r "s|^(\[)[[:xdigit:]]+(\]${package}\s*)$|\1${commit_sha}\2|g" "${marker}" || \
echo "[${commit_sha}]${package}" >> "${marker}"
rclone move "${marker}" "${DEPLOY_PATH}"
return 0
}

# Git configuration
git_config() {
    local name="${1}"
    local value="${2}"
    test -n "$(git config ${name})" && return 0
    git config --global "${name}" "${value}" && return 0
    failure 'Could not configure Git for makepkg'
}

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
    message "${status}"
    if [[ "${command}" != *:* ]]
        then ${command} ${arguments[@]}
        else ${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
}

# Sort packages by dependency
define_build_order() {
    local sorted_packages=()
    for unsorted_package in "${packages[@]}"; do
        _build_add "${unsorted_package}"
    done
    packages=("${sorted_packages[@]}")
}

# Added commits
list_commits()  {
    _list_changes commits '*' '#*::' --pretty=format:'%ai::[%h] %s'
}

# Changed recipes
list_packages() {
if false; then
    local _packages
    _list_changes _packages '*/PKGBUILD' '%/PKGBUILD' --pretty=format: --name-only || return 1
    for _package in "${_packages[@]}"; do
        local find_case_sensitive="$(find -wholename "./${_package}" -type d -print -quit)"
        test -n "${find_case_sensitive}" && packages+=("${_package}")
    done
    return 0
else
	packages=($(find ${PACMAN_REPO} -type f -name "PKGBUILD" | sed -r 's|(.*)/PKGBUILD|\1|'))
fi
}

# Add custom repositories to pacman
add_custom_repos()
{
[ -n "${CUSTOM_REPOS}" ] || { echo "You must set CUSTOM_REPOS firstly."; return 1; }
local repos=(${CUSTOM_REPOS//,/ })
local repo name
for repo in ${repos[@]}; do
name=$(sed -n -r 's/\[(\w+)\].*/\1/p' <<< ${repo})
[ -n "${name}" ] || continue
cp -vf /etc/pacman.conf{,.orig}
sed -r 's/]/&\nServer = /' <<< ${repo} >> /etc/pacman.conf
sed -i -r 's/^(SigLevel\s*=\s*).*/\1Never/' /etc/pacman.conf
pacman --sync --refresh --needed --noconfirm --disable-download-timeout ${name}-keyring && name="" || name="SigLevel = Never\n"
mv -vf /etc/pacman.conf{.orig,}
sed -r "s/]/&\n${name}Server = /" <<< ${repo} >> /etc/pacman.conf
done
}

# Function: Sign one or more pkgballs.
create_package_signature()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
local pkg
# signature for distrib packages.
[ -d ${ARTIFACTS_PATH}/${PACMAN_REPO} ] && {
pushd ${ARTIFACTS_PATH}/${PACMAN_REPO}
for pkg in *.pkg.tar.xz; do
expect << _EOF
spawn gpg --pinentry-mode loopback -o "${pkg}.sig" -b "${pkg}"
expect {
"Enter passphrase:" {
					send "${PGP_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done
popd
}
return 0
}

# Import pgp private key
import_pgp_seckey()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
[ -n "${PGP_KEY}" ] || { echo "You must set PGP_KEY firstly."; return 1; }
expect << _EOF
spawn bash -c "gpg --import --pinentry-mode loopback <<< '${PGP_KEY}'"
expect {
"Enter passphrase:" {
					send "${PGP_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
}

# Build package
build_package()
{
local depends makedepends arch buildarch
[ -n "${ARTIFACTS_PATH}" ] || { echo "You must set ARTIFACTS_PATH firstly."; return 1; }
_package_info "${package}" depends{,_${PACMAN_ARCH}} makedepends{,_${PACMAN_ARCH}} arch buildarch
[ -n "${buildarch}" ] && {
[ "$((buildarch & 1<<0))" == "$((1<<0))" ] && arch=(${arch[@]} 'i686' 'x86_64' 'arm' 'armv6h' 'armv7h' 'aarch64')
[ "$((buildarch & 1<<1))" == "$((1<<1))" ] && arch=(${arch[@]} 'arm')
[ "$((buildarch & 1<<2))" == "$((1<<2))" ] && arch=(${arch[@]} 'armv7h')
[ "$((buildarch & 1<<3))" == "$((1<<3))" ] && arch=(${arch[@]} 'aarch64')
[ "$((buildarch & 1<<4))" == "$((1<<4))" ] && arch=(${arch[@]} 'armv6h')
true
} || {
arch=(${arch[@]} "${PACMAN_ARCH}")
}
arch=($(tr ' ' '\n' <<< ${arch[@]} | sort -u))
grep -Pq "\b${PACMAN_ARCH}\b" <<< ${arch[@]} || { echo "The package will not build for architecture '${PACMAN_ARCH}'"; return 0; }
[ "$(_last_package_hash ${package})" == "$(_now_package_hash ${package})" ] && { echo "The package '${package}' has beed built, skip."; return 0; }

pushd "${package}"
sed -i -r "s|^(arch=\()[^)]+(\))|\1${arch[*]}\2|" PKGBUILD
[ -n "${depends}" ] && pacman -S --needed --noconfirm --disable-download-timeout ${depends[@]}
[ -n "$(eval echo \${depends_${PACMAN_ARCH}})" ] && eval pacman -S --needed --noconfirm --disable-download-timeout \${depends_${PACMAN_ARCH}[@]}
[ -n "${makedepends}" ] && pacman -S --needed --noconfirm --disable-download-timeout ${makedepends[@]}
[ -n "$(eval echo \${makedepends_${PACMAN_ARCH}})" ] && eval pacman -S --needed --noconfirm --disable-download-timeout \${makedepends_${PACMAN_ARCH}[@]}
runuser -u alarm -- makepkg --noconfirm --skippgpcheck --nocheck --syncdeps --rmdeps --cleanbuild

(ls *.pkg.tar.xz &>/dev/null) && {
mkdir -pv ${ARTIFACTS_PATH}/${PACMAN_REPO}
mv -vf *.pkg.tar.xz ${ARTIFACTS_PATH}/${PACMAN_REPO}
}
popd
}

# deploy artifacts
deploy_artifacts()
{
[ -n "${DEPLOY_PATH}" ] || { echo "You must set DEPLOY_PATH firstly."; return 1; } 
local old_pkgs pkg file
(ls ${ARTIFACTS_PATH}/${PACMAN_REPO}/*.pkg.tar.xz &>/dev/null) || { echo "Skiped, no file to deploy"; return 0; }
pushd ${ARTIFACTS_PATH}/${PACMAN_REPO}
export PKG_FILES=(${PKG_FILES[@]} $(ls *.pkg.tar.xz))
echo ::set-output name=pkgfile0::${PKG_FILES[@]}
for file in ${PACMAN_REPO}.{db,files}{,.tar.xz}{,.old}; do
rclone copy ${DEPLOY_PATH}/${PACMAN_REPO}/${file} ${PWD} 2>/dev/null || true
done
old_pkgs=($(repo-add "${PACMAN_REPO}.db.tar.xz" *.pkg.tar.xz | tee /dev/stderr | grep -Po "\bRemoving existing entry '\K[^']+(?=')"))
popd
for pkg in ${old_pkgs[@]}; do
for file in ${pkg}-{${PACMAN_ARCH},any}.pkg.tar.xz{,.sig}; do
rclone delete ${DEPLOY_PATH}/${PACMAN_REPO}/${file} 2>/dev/null || true
done
done
rclone move ${ARTIFACTS_PATH}/${PACMAN_REPO} ${DEPLOY_PATH}/${PACMAN_REPO} --copy-links
_record_package_hash "${package}"
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; exit 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; exit 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }
