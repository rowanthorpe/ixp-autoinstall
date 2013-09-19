#!/bin/sh

# Copyright (C) 2013 Rowan Thorpe
# All Rights Reserved.
#
# This file is part of ixp-autoinstall.
#
# ixp-autoinstall is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, version v2.0 of the License.
#
# ixp-autoinstall is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License v2.0
# along with ixp-autoinstall. If not, see:
#
# http://www.gnu.org/licenses/gpl-2.0.html
#
# ixp-autoinstall is for automating the install/update process for INEX's
# IXP-Manager - https://github.com/inex/IXP-Manager
# It initially derived heavily from the manual install instructions provided there.

## IXP-Manager auto-installer
##
## v0.2 (tested OK with IXP-Manager git master HEAD at 29/08/2013 23:00)
##
######
##
## NB:
##
##  * Alpha software! Backup everything (or preferably use empty initial OS
##    image) before use!
##
##  * Although theoretically this should install a "working" but bare
##    installation (ignoring the missing database dump and custom files
##    archives), the first install and setup should generally *not* be done with
##    this script. It is intended for reinstalling a production-ready instance
##    (i.e. to help with things like setting up puppet, migrations, etc).
##
##  * For now this is mostly a POC and is only guaranteed to work:
##    + on Debian Wheezy
##    + in single-ixp mode
##    + with a single switch
##    + with direct peerings (no route server)
##    + with IXPManager, mysql, sflow, mrtg, etc all hosted on the same server
##    + with a few other small restrictions I can't remember
##    ...obviously the intention is to reduce these restrictions in time...
##
##  * Great effort has been made to ensure each iteration of this script is as
##    "forwards-compatible" with future versions of IXP-Manager as possible,
##    (using sed instead of patch to cope with inserted/deleted conf-data,
##    etc), and there should be some degree of backwards-compatibility too, but
##    due to complexity there is never a guarantee. The version line at the top
##    of this script will always state which version of IXP-Manager it was last
##    officially tested against.
##
##  * This script should be intelligent enough to e.g. install into '/ixp' on a
##    running server with the old site running at '/' (it non-destructively
##    updates webserver configs rather than stomping on them if they already
##    exist). However this should be rigorously tested on a copy of the server
##    before/if-ever doing it on the production server(!).
##
######
##
## Example usage on typical VPS (bare Debian Wheezy image):
##
##  ++ {in a local terminal}
##  * cp ixp-autoinstall_conf.sh.dist ixp-autoinstall_conf.sh
##  * vi ixp-autoinstall_conf.sh {edit settings to your needs}
##  ++ {login to the VM through VNC or similar}
##  * passwd {and set root password}
##  * vi /etc/locale.gen {uncomment your desired locale if necessary}
##  * locale-gen
##  * aptitude update
##  * aptitude {ensure openssh-server is installed and running, and resolve
##              any broken deps or other inconsistencies if necessary}
##  * logout
##  ++ {now in local terminal again}
##  * scp ~/.ssh/id_rsa.pub root@{VM-IP-ADDRESS}:/root/.ssh/authorized_keys
##  * scp \
##     {PATH-TO}/ixp-autoinstall/* {PATH-TO}/ixpmanager_{ixpshortname}_*.{sql,tar} \
##     root@{VM-IP-ADDRESS}:/{IMPORTING_DIR_SPECIFIED_IN_CONFIG}
##  * ssh root@{VM-IP-ADDRESS}
##  * ./ixp-autoinstall.sh
##  * {you either have to enter mysql root password manually a few times - or
##     have no mysql root password during install - this is unavoidable for
##     security's sake for now}
##
######
##
## Motivations:
##
##  * My employer still needed to track latest versions of IXP-Manager as
##    releases development code didn't yet include some vital functionality
##    which they were waiting/hoping for (e.g. peering-matrix was still
##    non-functional due to unreleased code) so "stable version" still meant
##    "broken version" for us.
##
##  * I wanted to make migration and use of puppet, etc a much more realistic
##    option for us.
##
##  * The development code was still changing very rapidly and we had to keep a
##    close eye on stability (avoiding opportunities for user error on repeat
##    installs/updates).
##
##  * I structured the installer's config file to minimise how much actual text
##    needed to be edited/updated, etc.
##
##  * It would make a useful point-of-reference for the INEX team to speed up
##    their attempts to make the install process more automated internally and
##    less arduous for the user. As they improve IXP-Manager's install process
##    this installer should be able to become much less complex.
##
##  * I used base POSIX shell script syntax (no bashisms, etc) for both the
##    installer and its config for maximum portability (even using
##    variable-substitution for directory-separators, EOLs and null-devices so
##    it should be relatively platform agnostic for filesystem operations too -
##    e.g. Windows, etc - if IXP-Manager ever decides to go down that road...).
##    I encapsulated system-specific code in case statements for easy addition
##    of platforms.
##
######
##
## TODO:
##
##  * remove the restrictions mentioned in the "NB" above
##  * copy across other mrtg init tweaks from old VM
##  * add download-php-bcrypt-encrypt fixtures password step (so it can be set
##    in the config)
##  * cycle through potentially multiple values,commented if not used (e.g.
##    peering matrix LANs) when setting $sed_{config,fixtures}_tweaks (like was
##    done for server-aliases in $sed_webserver_tweaks)
##  * securely(?) automate all presently interactive requests for root password
##  * find a less crude way to kill default cron-run mrtg (pgrep the args too?)
##  * check if views need to be rebuilt when skin has been unarchived (added for
##    now just in case)
##  * confirm and add more OK platforms to sed_i and mkdir_p
##  * sed_i() presumes there is no-less/no-more than one input file, given as
##    last argument. Emulate real sed more accurately to future-proof it(?)
##  * extra finishing install steps (see bottom of script)
##
######

## paranoia... ##
set -e

## change $_d, $_null (and $_e ?!) per-platform if useful (unlikely) below ##
_d='/' # e.g. windows => '\'
_null="${_d}dev${_d}null" # e.g. windows => 'nul'
_e='
' # this will always use the platform's EOL

## default run-phases settings ##
do_install_firewall=1
do_install_deps=1
do_setup_dirs=1
do_setup_permissions=1
do_install_ixpmanager=1
do_create_database=1
do_edit_base_confs=1
do_setup_schema=1
do_setup_webserver=1
do_setup_fixtures=1
do_unarchive_skin=1
do_unarchive_misc=1
do_unarchive_ext_images=1
do_setup_maintenance_file=1
do_populate_db_data=1
do_setup_perl_libs=1
do_integrate_mrtg=1
do_setup_mrtg=1
do_setup_mrtg_init=1
do_setup_periodic_update=1
do_setup_periodic_update_cron=1
do_setup_store_traffic_cron=1
do_setup_update_macs=1
do_setup_poll_switch_cron=1
do_install_sflowtool=1
do_setup_rrdcached=1
do_setup_sflow_to_rrd=1
do_setup_sflow_to_rrd_init=1
do_let_sflow_through_firewall=1
do_integrate_sflow=1
do_setup_smokeping=1
do_integrate_smokeping=1
do_remove_build_deps=1
do_start_webserver=1
do_let_web_through_firewall=1

## default "options"
with_root_db_password=0

## parse opts ##
while test $# -gt 0; do
    case "$1" in
    --no-install-firewall)
        do_install_firewall=0
        shift
        ;;
    --no-install-deps)
        do_install_deps=0
        shift
        ;;
    --no-setup-dirs)
        do_setup_dirs=0
        shift
        ;;
    --no-setup-permissions)
        do_setup_permissions=0
        shift
        ;;
    --no-install-ixpmanager)
        do_install_ixpmanager=0
        shift
        ;;
    --no-create-database)
        do_create_database=0
        shift
        ;;
    --no-edit-base-confs)
        do_edit_base_confs=0
        shift
        ;;
    --no-setup-schema)
        do_setup_schema=0
        shift
        ;;
    --no-setup-webserver)
        do_setup_webserver=0
        shift
        ;;
    --no-setup-fixtures)
        do_setup_fixtures=0
        shift
        ;;
    --no-unarchive-skin)
        do_unarchive_skin=0
        shift
        ;;
    --no-unarchive-misc)
        do_unarchive_misc=0
        shift
        ;;
    --no-unarchive-ext-images)
        do_unarchive_ext_images=0
        shift
        ;;
    --no-setup-maintenance-file)
        do_setup_maintenance_file=0
        shift
        ;;
    --no-populate-db-data)
        do_populate_db_data=0
        shift
        ;;
    --no-setup-perl-libs)
        do_setup_perl_libs=0
        shift
        ;;
    --no-integrate-mrtg)
        do_integrate_mrtg=0
        shift
        ;;
    --no-setup-mrtg)
        do_setup_mrtg=0
        shift
        ;;
    --no-setup-mrtg-init)
        do_setup_mrtg_init=0
        shift
        ;;
    --no-setup-periodic-update)
        do_setup_periodic_update=0
        shift
        ;;
    --no-setup-periodic-update-cron)
        do_setup_periodic_update_cron=0
        shift
        ;;
    --no-setup-store-traffic-cron)
        do_setup_store_traffic_cron=0
        shift
        ;;
    --no-setup-update-macs)
        do_setup_update_macs=0
        shift
        ;;
    --no-setup-poll-switch-cron)
        do_setup_poll_switch_cron=0
        shift
        ;;
    --no-install-sflowtool)
        do_install_sflowtool=0
        shift
        ;;
    --no-setup-rrdcached)
        do_setup_rrdcached=0
        shift
        ;;
    --no-setup-sflow-to-rrd)
        do_setup_sflow_to_rrd=0
        shift
        ;;
    --no-setup-sflow-to-rrd-init)
        do_setup_sflow_to_rrd_init=0
        shift
        ;;
    --no-let-sflow-through-firewall)
        do_let_sflow_through_firewall=0
        shift
        ;;
    --no-integrate-sflow)
        do_integrate_sflow=0
        shift
        ;;
    --no-setup-smokeping)
        do_setup_smokeping=0
        shift
        ;;
    --no-integrate-smokeping)
        do_integrate_smokeping=0
        shift
        ;;
    --no-remove-build-deps)
        do_remove_build_deps=0
        shift
        ;;
    --no-start-webserver)
        do_start_webserver=0
        shift
        ;;
    --no-let-web-through-firewall)
        do_let_web_through_firewall=0
        shift
        ;;
    --with-root-db-password)
        with_root_db_password=1
        shift
        ;;
    --)
        shift
        break
        ;;
    -*)
        printf 'invalid option %s given%s' "$1" "${_e}" >&2
        exit 1
        ;;
    *)
        break
        ;;
    esac
done

## other setup values and functions ##
_d_esc="$(printf %s "$_d" | sed -e 's:\\:\\\\:g')" # backslash all backslashes (but *not* forward slashes...)
_e_esc="$(printf %s "$_e" | sed -e 's:\\:\\\\:g')" # same here
_null_esc="$(printf %s "$_null" | sed -e 's:\\:\\\\:g')" # same here
_d_sed="$(printf %s "$_d_esc" | sed -e 's%:%\\:%g')" # backslash all ':'s
_e_sed="$(printf %s "$_e_esc" | sed -e 's%:%\\:%g')" # same here
_null_sed="$(printf %s "$_null_esc" | sed -e 's%:%\\:%g')" # same here
scriptname="$(printf %s "$0" | sed -ne "\$ s:^.*${_d_sed}\([^${_d_sed}]\+\)\$:\1:; t PRINT; b; :PRINT p")"
confpath="$(printf '%s' "$0" | sed -e '$ s:.sh$:_conf.sh:')"
warn() {
    for arg in "$@"; do
        printf '%s: %s%s' "$scriptname" "$arg" "${_e}" >&2
    done
}
die() {
    warn "$@"
    exit 1
}

warn "getting platform info"
platform_name="`lsb_release -i -s`"
platform_version="`lsb_release -c -s`"
case "$platform_name" in
Debian|Ubuntu)
    DEBIAN_FRONTEND=noninteractive
    export DEBIAN_FRONTEND
    ;;
*)
    die "Platform not yet supported"
    ;;
esac

warn "sourcing vars in sed-safe (with : sed-delimiter) mode"
conffile_sed="`mktemp`"
trap 'rm "$conffile_sed" 2>${_null}' EXIT
sed -e 's%\\%\\\\%g; s%:%\\:%g' "$confpath" >"$conffile_sed"
. "$conffile_sed"

warn "setting sed scripts based on sourced vars"
sed_config_tweaks="\
  s:^\(reseller\.enabled = \)true\(\)\$:\1false\2:
  s:^\(resources\.auth\.oss\.pwhash  = \"\)plaintext\(\"\)\$:\1$auth_hash\2:
  s:^;\(resources\.auth\.oss\.hash_cost  = \)9\(\)\$:\1$auth_hash_cost\2:
  s:^\(resources\.doctrine2\.connection\.options\.dbname   = '\)ixp\('\)\$:\1$db_name\2:
  s:^\(resources\.doctrine2\.connection\.options\.user     = '\)ixp\('\)\$:\1$db_user\2:
  s:^\(resources\.doctrine2\.connection\.options\.password = '\)password\('\)\$:\1$db_pass\2:
  s:^\(resources\.doctrine2\.connection\.options\.host     = '127.0.0.1'\)\$:\1\\
resources.doctrine2.connection.options.charset  = 'utf8':
  s:^\(ondemand_resources\.logger\.writers\.email\.from   = \)ixp-logger@example\.com\(\)\$:\1$logger_email_from\2:
  s:^\(ondemand_resources\.logger\.writers\.email\.to     = \)ixp-notify-list@example\.com\(\)\$:\1$logger_email_to\2:
  s:^\(ondemand_resources\.logger\.writers\.stream\.path  = \)APPLICATION_PATH \"/\.\./var/log\"\(\)\$:\1\"$site_log_dir\"\2:
  s:^\(resources\.session\.save_path = \)APPLICATION_PATH \"/\.\./session\"\(\)\$:\1\"${site_cache_dir}${_d}session\"\2:
  s:^\(ondemand_resources\.mailer\.smtphost = \"\)127\.0\.0\.1\(\"\)\$:\1$mailer_host\2:
  s:^; \(ondemand_resources\.mailer\.username =\)\(\)\$:; \1$mailer_user\2 ;;TODO:
  s:^; \(ondemand_resources\.mailer\.password =\)\(\)\$:; \1$mailer_pass\2 ;;TODO:
  s:^; \(ondemand_resources\.mailer\.auth = \)login | plain | cram-md5\(\)\$:; \1$mailer_auth\2 ;;TODO:
  s:^;; \(resources.smarty.skin      = \"\)\(\"\)\$:\1$skin_name\2:
  s:^\(resources\.smarty\.compiled  = \)APPLICATION_PATH \"/\.\./var/templates_c\"\(\)\$:\1\"${site_cache_dir}${_d}templates_c\"\2:
  s:^\(resources\.smarty\.cache     = \)APPLICATION_PATH \"/\.\./var/cache\"\(\)\$:\1\"${site_cache_dir}${_d}smarty\"\2:
  s:^\(identity\.orgname  = \"\)XXX\(\"\)\$:\1$id_orgname\2:
  s:^\(identity\.name  = \"\)XXX Operations\(\"\)\$:\1$id_name\2:
  s:^\(identity\.email = \"\)operations@example\.com\(\"\)\$:\1$id_email\2:
  s:^\(identity\.autobot\.name  = \"\)XXX Ops Autobot\(\"\)\$:\1$id_autobot_name\2:
  s:^\(identity\.autobot\.email = \"\)ops-auto@example\.com\(\"\)\$:\1$id_autobot_email\2 ;;TODO:
  s:^\(identity\.mailer\.name   = \"\)XXX Autobot\(\"\)\$:\1$id_mailer_name\2:
  s:^\(identity\.mailer\.email  = \"\)do-not-reply@example\.com\(\"\)\$:\1$id_mailer_email\2 ;;TODO:
  s:^\(identity\.sitename = \"\)XXX IXP Manager\(\"\)\$:\1$id_sitename\2:
  s:^\(identity\.url = \"\)https\://www\.example\.com/ixp/\(\"\)\$:\1$id_url\2:
  s:^\(identity\.logo = \)APPLICATION_PATH \(\"\)/\.\./public/images/inex-logo-150x73\.jpg\(\"\)\$:\1\2$id_logo_file\3:
  s:^\(identity\.biglogo = \"\)https\://www\.inex\.ie/ixp/images/inex-logo-600x165\.gif\(\"\)\$:\1$id_biglogo_file\2:
  s:^\(identity\.biglogoconf\.offset = \)offset4\(\)\$:identity.logoconf.offset = offset3\\
\1offset3\2:
  s:^\(identity\.misc\.irc_password = \"\)xxx\(\"\)\$:\1$id_irc_pass\2 ;;TODO:
  s:^\(identity\.switch_domain = \"\)\.example\.com\(\"\)\$:\1$id_switch_domain\2:
  s:^\(identity\.default_country = '\)IE\('\)\$:\1$id_countrycode\2:
  s:^\(mrtg\.conf\.workdir = '\)/home/mrtg\('\)\$:\1$mrtg_data_dir\2:
  s:^;\(mrtg\.conf\.dstfile = '\)/tmp/mrtg\.cfg\('\)\$:\1$mrtg_config_file\2:
  s:^;\(smokeping\.conf\.dstfile = '\)/etc/smokeping/config\('\)\$:\1$smokeping_config_file\2:
  s:^\(smokeping\.conf\.cgiurl = \"\)https\://www.example.com/smokeping/smokeping.cgi\(\"\)\$:\1${site_proto}\://${site_ip_v4}/smokeping/smokeping.cgi\2:
  s:^\(smokeping\.conf\.imgcache = \"\)/usr/local/smokeping/htdocs/img\(\"\)\$:\1/var/cache/smokeping/images\2:
  s:^\(smokeping\.conf\.imgurl = \"\)/smokeping/img\(\"\)$:\1/smokeping/images\2:
  s:^\(smokeping\.conf\.datadir = \"\)/usr/local/var/smokeping\(\"\)\$:\1/var/lib/smokeping\2:
  s:^\(smokeping\.conf\.piddir = \"\)/usr/local/var/smokeping\(\"\)\$:\1/var/run/smokeping\2:
  s:^\(smokeping\.conf\.smokemail = \"\)/usr/local/etc/smokeping/smokemail\(\"\)\$:\1/etc/smokeping/smokemail\2:
  s:^\(smokeping\.conf\.pathnames = \"\)/etc/smokeping/config.d/pathnames\(\"\)\$:;\1/etc/smokeping/config.d/pathnames\2:
  s:^\(smokeping\.oconf\.tmail = \"\)/usr/local/etc/smokeping/tmail\(\"\)\$:\1/etc/smokeping/tmail\2:
  s:^\(sflow\.rootdir = \)/path/to/rrd/files\(\)\$:\1$sflow_rrd_dir\2:
  s:^\(sflow\.rrd\.rrdcached\.sock = \)unix\:/var/run/rrdcached\.sock\(\)\$:\1$rrdcached_sock\2:
  s:^\(peering_matrix\.public\.0\.name   = \"\)Public Peering LAN #1\(\"\)\$:\1$peering_matrix_0_name\2:
  s:^\(peering_matrix\.public\.0\.number = \)100\(\)\$:\1$peering_matrix_0_num\2:
  s:^\(peering_matrix\.public\.1\.name   = \"\)Public Peering LAN #2\(\"\)\$:;\1$peering_matrix_1_name\2:
  s:^\(peering_matrix\.public\.1\.number = \)120\(\)\$:;\1$peering_matrix_1_num\2:
  s:^\(primary_peering_lan\.vlan_tag = \)100\(\)\$:\1$peering_matrix_0_num\2:
  s:^\(cli\.traffic_differentials\.from_email = \"\)ops@example\.com\(\"\)\$:\1$traffic_differentials_email\2:
  s:^\(cli\.traffic_differentials\.from_name  = \"\)XXX Operations\(\"\)\$:\1$traffic_differentials_name\2:
  s:^\(cli\.traffic_differentials\.subject = \"\)XXX Traffic Differentials\(\"\)\$:\1$traffic_differentials_subject\2:
  s:^\(cli\.traffic_differentials\.recipients\[\] = \"\)someone@example\.com\(\"\)\$:\1$traffic_differentials_recipient\2:
  s:^\(cli\.traffic_differentials\.recipients\[\] = \"\)someone-else@example\.com\(\"\)\$:\1$traffic_differentials_recipient_extra\2:
  s:^\(cli\.port_utilisation\.from_email = \"\)ops@example\.com\(\"\)\$:\1$port_utilisation_email\2:
  s:^\(cli\.port_utilisation\.from_name  = \"\)XXX Operations\(\"\)\$:\1$port_utilisation_name\2:
  s:^\(cli\.port_utilisation\.subject = \"\)XXX Port Utilisation Report\(\"\)\$:\1$port_utilisation_subject\2:
  s:^\(cli\.port_utilisation\.recipients\[\] = \"\)someone@example\.com\(\"\)\$:\1$port_utilisation_recipient\2:
  s:^\(cli\.port_utilisation\.recipients\[\] = \"\)someone-else@example\.com\(\"\)\$:\1$port_utilisation_recipient_extra\2:
  s:^\(cli\.ports_with_counts\.from_email = \"\)ops@example\.com\(\"\)\$:\1$ports_with_counts_email\2:
  s:^\(cli\.ports_with_counts\.from_name  = \"\)IXP Operations\(\"\)\$:\1$ports_with_counts_name\2:
  s:^\(cli\.ports_with_counts\.subject = \"\)IXP - Ports with %s\(\"\)\$:\1$ports_with_counts_subject\2:
  s:^\(cli\.ports_with_counts\.recipients\[\] = \"\)someone@example\.com\(\"\)\$:\1$ports_with_counts_recipient\2:
  s:^\(cli\.ports_with_counts\.recipients\[\] = \"\)someone-else@example\.com\(\"\)\$:\1$ports_with_counts_recipient_extra\2:
  s:^\(meeting\.rsvp_to_email = \"\)rsvp@example\.com\(\"\)\$:\1$rsvp_email\2 ;;TODO:
  s:^\(meeting\.rsvp_to_name  = \"\)Person Who Looks After This Stuff\(\"\)\$:\1$rsvp_name\2 ;;TODO:
  s:^\(weathermap\.1\.[a-z]\+ \+=\):;\1:
"
sed_fixtures_tweaks="\
  s:^\(date_default_timezone_set('\)Europe/Dublin\(');\)\$:\1$locale_timezone\2:
  s:^\(setlocale(LC_ALL, \"\)en_IE\.utf8\(\");\)\$:\1$locale_code\2:
  s:^\(\\\$ixp->setName( \"\)Somecity Internet Exchange Point\(\" );\)\$:\1$ixp_longname\2:
  s:^\(\\\$ixp->setShortname( \"\)SIEP\(\" );\)\$:\1$ixp_shortname\2:
  s:^\(\\\$ixp->setAddress1( \"\)5 Somewhere\(\" );\)\$:\1$ixp_address_1\2:
  s:^\(\\\$ixp->setAddress2( \"\)Somebourogh\(\" );\)\$:\1$ixp_address_2\2:
  s:^\(\\\$ixp->setAddress3( \"\)Dublin\(\" );\)\$:\1$ixp_city\2:
  s:^\(\\\$ixp->setAddress4( \"\)D4\(\" );\)\$:\1$ixp_postcode\2:
  s:^\(\\\$ixp->setCountry( '\)IE\(' );\)\$:\1$ixp_countrycode\2:
  s:^\(\\\$infra1->setName( \"\)Infrastructure #1\(\" );\)\$:\1$primary_infra_name\2:
  s:^\(\\\$c->setName( \"\)Somecity Internet Exchange Point\(\" );\)\$:\1$ixp_longname\2:
  s:^\(\\\$c->setAbbreviatedName( '\)SIEP\(' ); // shorter name for graphs, etc\)\$:\1$ixp_shortname\2:
  s:^\(\\\$c->setShortname( \"\)siep\(\" );        // lowercase abbreviation (e\.g\. inex/ linx / lonap)\)\$:\1$ixp_abbrevname_lc\2:
  s:^\(\\\$c->setAutsys( \)12345\( );            // your ASN\)\$:\1$ixp_asn\2:
  s:^\(\\\$c->setMaxprefixes( \)1000\( );        // set appropriately if you peer with other members on the\)\$:\1$max_prefixes\2:
  s:^\(\\\$c->setPeeringemail( '\)peering@lonap\.net\(' );\)\$:\1$peering_email\2:
  s:^\(\\\$c->setPeeringmacro( '\)AS-SIEP\(' );\)\$:\1$peering_macro\2:
  s:^\(\\\$c->setPeeringmacrov6( '\)AS-SIEP6\(' );\)\$:\1$peering_macro_v6\2:
  s:^\(\\\$c->setNocphone( '\)+353 1 123 4567\(' );\)\$:\1$noc_phone\2:
  s:^\(\\\$c->setNoc24hphone( '\)+353 1 123 4567\(' );\)\$:\1$noc_24h_phone\2:
  s:^\(\\\$c->setNocfax( '\)+353 1 123 4568\(' );\)\$:\1$noc_fax\2:
  s:^\(\\\$c->setNocemail( '\)noc@siep\.com\(' );\)\$:\1$noc_email\2:
  s:^\(\\\$c->setNocwww( '\)http\://www\.siep\.com/noc/\(' );\)\$:\1$noc_www\2:
  s:^\(\\\$c->setCorpwww( '\)http\://www\.siep\.com/\(' );\)\$:\1$noc_corp_www\2:
  s:^\(\\\$crd->setRegisteredName( '\)Somecity Internet Exchange Point Limited\(' );\)\$:\1$reg_name\2:
  s:^\(\\\$crd->setCompanyNumber( '\)123456\(' );\)\$:\1$reg_company_number\2:
  s:^\(\\\$crd->setJurisdiction( '\)Ireland\(' );\)\$:\1$reg_jurisdiction\2:
  s:^\(\\\$crd->setAddress1( '\)5 Somewhere\(' );\)\$:\1$reg_address_1\2:
  s:^\(\\\$crd->setTownCity( '\)Dublin\(' );\)\$:\1$reg_city\2:
  s:^\(\\\$crd->setPostcode( '\)D4\(' );\)\$:\1$reg_postcode\2:
  s:^\(\\\$crd->setCountry( '\)IE\(' );\)\$:\1$reg_countrycode\2:
  s:^\(\\\$cbd->setBillingAddress1( '\)c/o The Bill Payers\(' );\)\$:\1$billing_address_1\2:
  s:^\(\\\$cbd->setBillingAddress2( '\)Money House, Moneybags Street\(' );\)\$:\1$billing_address_2\2:
  s:^\(\\\$cbd->setBillingTownCity( '\)Dublin\(' );\)\$:\1$billing_city\2:
  s:^\(\\\$cbd->setBillingPostcode( '\)D4\(' );\)\$:\1$billing_postcode\2:
  s:^\(\\\$cbd->setBillingCountry( '\)IE\(' );\)\$:\1$billing_countrycode\2:
  s:^\(\\\$contact->setName( '\)Joe Bloggs\(' );\)\$:\1$contact_name\2:
  s:^\(\\\$contact->setPosition( '\)Master of the Universe\(' );\)\$:\1$contact_position\2:
  s:^\(\\\$contact->setEmail( '\)joe@siep\.com\(' );\)\$:\1$contact_email\2:
  s:^\(\\\$contact->setPhone( '\)+353 86 123 4567\(' );\)\$:\1$contact_phone\2:
  s:^\(\\\$contact->setMobile( '\)+353 1 123 4567\(' );\)\$:\1$contact_phone_mob\2:
  s:^\(\\\$u->setUsername( '\)username\(' );\)\$:\1superuser\2:
  s:^\(\\\$u->setPassword( '\)letmein1\(' );        // if you're not using plaintext passwords, put anything here and\)\$:\1\$2y\$09\$XspY/Bi8NJgwevC2qa1JtuYJ4ek5jki3a2.Oj0zjQvkKS4mDCYRrm\2:
"
sed_webserver_tweaks="\
  s:^\([	 ]*\)\(</VirtualHost>\)[	 ]*\$:\\
\1	Alias $site_base_url ${repo_dir}/public\\
\1	<Directory ${repo_dir}/public>\\
\1		Options FollowSymLinks\\
\1		AllowOverride None\\
\1		Order deny,allow\\
\1		Allow from all\\
\\
\1		SetEnv APPLICATION_ENV production\\
\\
\1		RewriteEngine On\\
\1		RewriteCond %{REQUEST_FILENAME} -s [OR]\\
\1		RewriteCond %{REQUEST_FILENAME} -l [OR]\\
\1		RewriteCond %{REQUEST_FILENAME} -d\\
\1		RewriteRule ^.*\$ - [NC,L]\\
\1		RewriteRule ^.*\$ ${site_base_url}`test '/' = "$site_base_url" || printf /`index.php [NC,L]\\
\1	</Directory>\\
\1\2:
"
sed_webserver_newconfig_tweaks="\
  s:^\([	 ]*\)ServerAdmin webmaster@localhost[	 ]*\$:\
\1ServerAdmin webmaster@$site_domain\\
\1ServerName  $site_name$(for arg in $site_aliases; do printf "\\
\\\\1ServerAlias %s" "$arg"; done):
"
sed_mrtg_init_tweaks="\
  /^DAEMON_ARGS=\"\/etc\/mrtg\/mrtg\.cfg\"\$/ d
  s:^\(PIDFILE=\)/etc/mrtg/\$NAME\.pid\(\)\$:\1\"${mrtg_pid_dir}${_d_sed}\$NAME.pid\"\2\\
DAEMON_ARGS=\"--daemon --user=www-data --group=www-data --pid-file=\$PIDFILE /etc/\$NAME/\$NAME.cfg\":
  s:^\([	 ]*\)\(start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 \\\\\)\$:\1env LANG=C \2:
"
sed_perl_configmod_tweaks="\
  s:^\([	 ]*configfile[	 ]\+=>[	 ]\+'\)/usr/local/etc\(/ixpmanager.conf',[	]*\)\$:\1${etc_dir}\2:
"
sed_perl_config_tweaks="\
  s:^\([	 ]*rs_[a-z_]\+ = \):#\1:
  s:^\([	 ]*dbase_database[	 ]\+=[	 ]\+\)ixpmanagerdatabase\(\)\$:\1$db_name\2:
  s:^\([	 ]*dbase_username[	 ]\+=[	 ]\+\)ixpmanagerusername\(\)\$:\1$db_user\2:
  s:^\([	 ]*dbase_password[	 ]\+=[	 ]\+\)mys00persekr1tp4ssw0rd\(\)\$:\1$db_pass\2:
"
sed_rrdcached_config_tweaks="\
  s:^#\(OPTS=\"\)\(\"\)\$:\1-P FLUSH,UPDATE -m 0666 -l $rrdcached_sock -j ${rrdcached_data_dir}${_d_sed}journal/ -F -b ${rrdcached_data_dir}${_d_sed}db${_d_sed}\2:
"
sed_control_sflow_tweaks="\
  s:^\([	 ]*program_args[	 ]\+=>[	 ]\+\[\)\(\],\)\$:\1'--sflowtool' => '${custom_scripts_dir}${_d_sed}sflowtool', '--sflowtool_opts' => '$sflowtool_opts', '--sflow_rrddir' => '$sflow_rrd_dir'\2:
  s:^\([	 ]*pid_file[	 ]\+=>[	 ]\+'\)/var/run/sflow-to-rrd-handler.pid\(',\)\$:\1${sflow_pid_dir}${_d_sed}sflow-to-rrd-handler.pid\2:
"
sed_sflow_handler_tweaks="\
  s:^\(my \\\$sflowtool = defined(\\\$ixp->{ixp}->{sflowtool}) ? \\\$ixp->{ixp}->{sflowtool} \: '\)/usr/bin/sflowtool\(';\)\$:\1${custom_scripts_dir}${_d_sed}sflowtool\2:
  s:^\(my \\\$basedir = defined(\\\$ixp->{ixp}->{sflow_rrddir}) ? \\\$ixp->{ixp}->{sflow_rrddir} \: '\)/data/ixpmatrix\(';\)\$:\1$sflow_rrd_dir\2:
"
sed_sflow_firewall_tweaks="\
  s:^\([	 ]*\)\(proto tcp dport ssh ACCEPT;\)[	 ]*\$:\1\2\\
\\
\1# allow incoming sflow data from main switch\\
\1proto udp dport $sflowtool_port saddr @ipfilter($primary_switch_ip) ACCEPT;:
"
sed_webserver_firewall_tweaks="\
  s:^\([	 ]*\)\(proto tcp dport ssh ACCEPT;\)[	 ]*\$:\1\2\\
\\
\1# allow HTTP connections\\
\1proto tcp dport (http https) `test -z "$site_source_ips" || printf 'saddr @ipfilter((%s)) ' "$site_source_ips"`ACCEPT;:
"
sed_sflow_graph_tweaks="\
  s:^\(set_include_path(get_include_path() \. PATH_SEPARATOR \. \)dirname( __FILE__ ) \. \"/\.\./\.\./library\"\();\)\$:\1\"${repo_dir}/library\"\2:
  s:^\(require '\)\.\./\.\./library/Zend/Config/Ini\.php\(';\)\$:\1${repo_dir}/library/Zend/Config/Ini.php\2:
  s:^\(require '\)\.\./\.\./bin/utils\.inc\(';\)\$:\1/opt/ixpmanager/bin/utils.inc\2:
  s:^\(\\\$config = new Zend_Config_Ini('\)\.\./\.\./application/configs/application\.ini\(', scriptutils_get_application_env());\)\$:\1/opt/ixpmanager/application/configs/application.ini\2:
  s:^\(\\\$srcvli = \\\$_REQUEST\['\)srcvli\('\];\)\$:\1srcvid\2:
  s:^\(\\\$dstvli = \\\$_REQUEST\['\)dstvli\('\];\)\$:\1dstvid\2:
"

warn "re-sourcing vars in non-sed-friendly mode"
. "$confpath"
rm "$conffile_sed"
siteconfsuffix="$(test "$site_proto" = http || printf %s -ssl)"

warn "setting deps"
case "$platform_name:$platform_version" in
Debian:wheezy)
    runtime_deps_minver="\
 perl>=5.10.2 \
 php5>=5.4 \
"
    if test $with_root_db_password = 1; then
        runtime_deps_minver_interact="\
 mysql-server>=5.3 \
"
    else
        runtime_deps_minver="\
 $runtime_deps_minver \
 mysql-server>=5.3 \
"
    fi
    runtime_deps_anyver="\
 apache2-mpm-prefork \
 apache2 \
 git \
 libconfig-general-perl \
 libdaemon-control-perl \
 libdbi-perl \
 libnet-ip-perl \
 libnet-snmp-perl \
 libnetaddr-ip-perl \
 librrds-perl \
 memcached \
 mrtg \
 mrtg-rrd \
 php-pear \
 php-apc \
 php-gettext \
 php5-memcache \
 php5-mysqlnd \
 php5-snmp \
 rrdcached \
 rrdtool \
 smokeping \
 subversion \
"
    build_deps="\
 dnsutils \
 gcc \
 libtool \
 make \
 sudo \
 wget \
"
    ;;
esac

warn "setting other vars and functions"
test -n "$site_ip_v4" || site_ip_v4="`dig +short -q "$site_name" A | tail -n 1`"
test -n "$site_ip_v6" || site_ip_v6="`dig +short -q "$site_name" AAAA | tail -n 1`"
case "$platform_name" in
Debian|Ubuntu)
    webserver_config_dir="${etc_dir}${_d}apache2"
    webserver_config_av_dir="${webserver_config_dir}/sites-available"
    webserver_config_en_dir="${webserver_config_dir}/sites-enabled"
    webserver_default_config_file="${webserver_config_av_dir}/default"
    if test https = "$site_proto"; then
        webserver_default_config_file="${webserver_default_config_file}-ssl"
    fi
    create_new_site_config=0
    test -s "${webserver_config_av_dir}${_d}$site_name$siteconfsuffix" || create_new_site_config=1
    ;;
esac

warn "setting internal functions"
sed_i() {
    test $# -gt 0 || return 1
    case "$platform_name" in
    Debian|Ubuntu)
        sed -i "$@"
        ;;
    *)
        sedtemp="`mktemp`"
        sed "$@" >"$sedtemp"
        shift `expr $# - 1`
        sedinput="$1"
        chown --reference="$sedinput" "$sedtemp"
        chmod --reference="$sedinput" "$sedtemp"
        mv "$sedtemp" "$sedinput"
        ;;
    esac
}
mkdir_p () {
    case "$platform_name" in
    Debian|Ubuntu)
        mkdir -p "$@"
        ;;
    *)
        if test $# -ne 1; then
            printf 'mkdir_p: please provide only one argument%s' "${_e}"
            return 1
        fi
        OIFS="$IFS"
        IFS="$_d"
        par=
        for arg in $@; do
            test -n "$arg" || arg="$_d"
            case "$par" in
                "$_d") par="$par$arg";;
                '') par="$arg";;
                *) par="$par${_d}$arg";;
            esac
            if ! test -d "$par"; then
                if ! test -e "$par"; then
                    mkdir "$par"
                    retval=$?
                    if test 0 -ne "$retval"; then
                        IFS="$OIFS"
                        return $retval
                    fi
                else
                    printf 'mkdir_p: cannot create directory ‘%s’: Not a directory%s' "$par" "${_e}"
                    IFS="$OIFS"
                    return 1
                fi
            fi
        done
        IFS="$OIFS"
        return 0
        ;;
    esac
}

###### Up to here was just setting vars, etc (repeatable). From here begin the "actions"... ######

if test "$do_install_firewall" -eq 1; then
    warn "installing firewall"
    case "$platform_name" in
    Debian|Ubuntu)
        aptitude install -y ferm
        invoke-rc.d ferm restart
        ;;
    esac
fi

if test "$do_install_deps" -eq 1; then
    warn "installing deps"
    case "$platform_name" in
    Debian|Ubuntu)
        for pkgspec in $runtime_deps_minver_interact; do
            pkgname=`printf %s "$pkgspec" | sed -e 's:>=.\+$::'`
            pkgminver=`printf %s "$pkgspec" | sed -e 's:^.\+>=::'`
            DEBIAN_FRONTEND=dialog aptitude -q -y install "$pkgname"
            instver=`dpkg-query -W -f '${Version}' "$pkgname"`
            dpkg --compare-versions "$instver" ge "$pkgminver" || die "package requires minimum version $pkgminver to be installed but we installed $instver"
        done
        for pkgspec in $runtime_deps_minver; do
            pkgname=`printf %s "$pkgspec" | sed -e 's:>=.\+$::'`
            pkgminver=`printf %s "$pkgspec" | sed -e 's:^.\+>=::'`
            aptitude -q -y install "$pkgname"
            instver=`dpkg-query -W -f '${Version}' "$pkgname"`
            dpkg --compare-versions "$instver" ge "$pkgminver" || die "package requires minimum version $pkgminver to be installed but we installed $instver"
        done
        test -z "$runtime_deps_anyver_interact" || DEBIAN_FRONTEND=dialog aptitude -q -y install $runtime_deps_anyver_interact
        aptitude -q -y install $runtime_deps_anyver
        apt-get -q -y install $build_deps
        ;;
    esac
fi

if test "$do_setup_dirs" -eq 1; then
    warn "setting up dirs"
    for eachdir in "$repo_dir" "$site_log_dir" "${site_cache_dir}${_d}templates_c" "${site_cache_dir}${_d}session" "${site_cache_dir}${_d}smarty" \
                   "$smokeping_image_cache_dir" "$smokeping_data_dir" "$smokeping_pid_dir" "$sflow_rrd_dir" "${web_dir}/sflow" \
                   "${mrtg_data_dir}${_d}members" "${mrtg_data_dir}${_d}switches" "$mrtg_config_dir" "$custom_src_dir" $external_images_dir; do
        if test -n "$eachdir" && ! test -e "$eachdir"; then
            mkdir_p "$eachdir"
        fi
    done
fi

if test "$do_install_ixpmanager" -eq 1; then
    warn "installing ixpmanager and its deps"
    cd "$base_dir"
    git clone -b "$repo_branch" "https://github.com/${git_user}/IXP-Manager.git" "$repo_name"
    cd "$repo_name"
    git submodule init
    git submodule update
    pear channel-discover 'pear.symfony.com' || true
    pear channel-discover 'pear.doctrine-project.org' || true
    pear install 'doctrine/DoctrineORM' || true
    case "$platform_name" in
    Debian|Ubuntu)
        test -e /usr/share/php/Doctrine/Symfony || ln -s '../Symfony' '/usr/share/php/Doctrine/Symfony'
        ;;
    esac
fi

if test "$do_setup_permissions" -eq 1; then
    warn "setting up permissions"
    for eachdir in "$repo_dir" "$site_log_dir" "$site_cache_dir" "$smokeping_image_cache_dir" "$sflow_rrd_dir" "${web_dir}/sflow" "$mrtg_data_dir" "$mrtg_lock_dir" "$external_images_dir"; do
        if test -n "$eachdir" && test -d "$eachdir"; then
            chown -R www-data:www-data "$eachdir"
            chmod -R u=rwX,g=rX,o= "$eachdir"
        fi
    done
fi

if test "$do_create_database" -eq 1; then
    warn "creating database"
    cd "$repo_dir"
    mysql --default-character-set=utf8 -u 'root' `test $with_root_db_password -eq 0 || printf -- -p` <<EOS
CREATE DATABASE \`$db_name\`;
GRANT ALL ON \`$db_name\`.* to \`$db_user\`@\`127.0.0.1\` IDENTIFIED BY '$db_pass';
GRANT ALL ON \`$db_name\`.* to \`$db_user\`@\`localhost\` IDENTIFIED BY '$db_pass';
FLUSH PRIVILEGES;
EOS
fi

if test "$do_edit_base_confs" -eq 1; then
    warn "editing base configs"
    cd "$repo_dir"
    sed -e "$sed_config_tweaks" "application${_d}configs${_d}application.ini.dist" >"application${_d}configs${_d}application.ini"
    sed -e '1 s:^\(SetEnv APPLICATION_ENV\) development$:\1 production:' "public${_d}.htaccess.dist" >"public${_d}.htaccess"
fi

if test "$do_setup_schema" -eq 1; then
    warn "setting up db schema and views"
    cd "$repo_dir"
    cd "bin"
    ".${_d}doctrine2-cli.php" 'orm:schema-tool:create'
    cd ..
    cat "tools${_d}sql${_d}views.sql" | mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name"
fi

if test "$do_setup_webserver" -eq 1; then
    warn "setting up webserver"
    cd "$repo_dir"
    test "$create_new_site_config" -eq 0 || sed -e "$sed_webserver_newconfig_tweaks" "$webserver_default_config_file" >"${webserver_config_av_dir}${_d}$site_name$siteconfsuffix"
    sed_i -e "$sed_webserver_tweaks" "${webserver_config_av_dir}${_d}$site_name$siteconfsuffix"
### TODO
#    if test https = "$site_proto" && test yes = "$site_redirect_non_https"; then
#        webserver_non_https_v4_conf_file="$(grep -l "^[	 ]*</VirtualHost \(*\|\([^>]\+ \)\?${site_ip_v4}\( [^>]\+\)\?\)\(:80\)\?>[	 ]*\$" "${webserver_config_en_dir}${_d}"* 2>$_null || true)"
#        webserver_non_https_v6_conf_file="$(grep -l "^[	 ]*</VirtualHost \(*\|\([^>]\+ \)\?\[${site_ip_v6}\]\( [^>]\+\)\?\)\(:443\)\?>[	 ]*\$" "${webserver_config_en_dir}${_d}"* 2>$_null || true)"
#        if test -n "$webserver_non_https_v4_conf_file"; then
#            if test 1 -eq `printf '%s%s' "$webserver_non_https_v4_conf_file" "${_e}" | wc -l`; then
#                sed_i -e "/^[	 ]*<VirtualHost \(*\|\([^>]\+ \)\?\[${site_ip_v4}\]\( [^>]\+\)\?\)\(:80\)\?>[	 ]*\$/,/^[	 ]*</VirtualHost>[	 ]*\)\$/ s:\(^[	 ]*</VirtualHost>[	 ]*\)\$:    Redirect permanent ${site_base_url} ${site_url}$site_base_url\\
#\1:" "${webserver_config_en_dir}${_d}"*
#            fi
#        else
#            cat >"${webserver_config_av_dir}${_d}ixp-redirect-to-https-v4" <<EOS
#<VirtualHost ${site_ip_v4}:80>
#    Redirect permanent $site_base_url ${site_url}$site_base_url
#</VirtualHost>
#EOS
#            a2ensite 'ixp-redirect-to-https-v4'
#        fi
#        if test -n "$webserver_non_https_v6_conf_file"; then
#            if test 1 -eq `printf '%s%s' "$webserver_non_https_v6_conf_file" "${_e}" | wc -l`; then
#                sed_i -e "/^[	 ]*<VirtualHost \(*\|\([^>]\+ \)\?\[${site_ip_v6}\]\( [^>]\+\)\?\)\(:443\)\?>[	 ]*\$/,/^[	 ]*</VirtualHost>[	 ]*\)\$/ s:\(^[	 ]*</VirtualHost>[	 ]*\)\$:    Redirect permanent ${site_base_url} ${site_url}$site_base_url\\
#\1:" "${webserver_config_en_dir}${_d}"*
#            fi
#        else
#            cat >"${webserver_config_av_dir}${_d}ixp-redirect-to-https-v6" <<EOS
#<VirtualHost [${site_ip_v6}]:443>
#    Redirect permanent $site_base_url ${site_url}/$site_base_url
#</VirtualHost>
#EOS
#            a2ensite 'ixp-redirect-to-https-v6'
#        fi
#    fi
###
    a2enmod 'rewrite'
    ! test "$site_proto" = https || a2enmod 'ssl'
    if test "$create_new_site_config" -eq 1; then
        a2ensite "$site_name$siteconfsuffix"
        a2dissite "default$siteconfsuffix" || true
    fi
fi

if test "$do_setup_fixtures" -eq 1; then
    warn "setting up fixtures"
    cd "$repo_dir"
    cd "bin"
    sed -e "$sed_fixtures_tweaks" 'fixtures.php.dist' >'fixtures.php'
    chown www-data:www-data 'fixtures.php'
    chmod +x 'fixtures.php'
    sudo -u www-data ".${_d}fixtures.php"
    cd ..
fi

if test "$do_unarchive_skin" -eq 1; then
    warn "unarchiving skin files"
    cd "$repo_dir"
    if test -s "$installer_skin_file"; then
        cd "application${_d}views${_d}_skins"
        tar -x -p -f "$installer_skin_file"
        cd "..${_d}..${_d}.."
    fi
fi

if test "$do_unarchive_misc" -eq 1; then
    warn "unarchiving misc files"
    cd "$repo_dir"
    if test -s "$installer_misc_file"; then
        tar -x -p -f "$installer_misc_file"
    fi
fi

if test "$do_unarchive_ext_images" -eq 1; then
    warn "unarchiving external image files"
    cd "$repo_dir"
    if test -d "$external_images_dir"; then
        cd "$external_images_dir"
        if test -s "$installer_images_file"; then
            tar -x -p -f "$installer_images_file"
        fi
        if test -s "favicon.ico" && ! test -e "${web_dir}${_d}favicon.ico"; then
            ln -s "$(printf %s%sfavicon.ico "${external_images_base_dir}" "$(test "$external_images_base_dir" = "$_d" || printf %s "$_d")" | sed -e "s:^${_d}::")" "${web_dir}${_d}favicon.ico"
        fi
    fi
fi

if test "$do_setup_maintenance_file" -eq 1; then
    warn "setting up maintenance mode file"
    cd "$repo_dir"
    cp public/maintenance.dist.php public/maintenance.php
    touch MAINT_MODE_ENABLED
fi

if test "$do_populate_db_data" -eq 1; then
    warn "populating db data"
    cd "$repo_dir"
    if test -s "$installer_database_file"; then
	    cat "$installer_database_file" | mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name"
    fi
    cat "tools${_d}sql${_d}views.sql" | mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name"
    case "$platform_name" in
    Debian|Ubuntu)
        invoke-rc.d memcached restart
        ;;
    esac
fi

if test "$do_setup_perl_libs" -eq 1; then
    warn "setting up perl libs"
    cd "$repo_dir"
    sed_i -e "$sed_perl_configmod_tweaks" "tools${_d}perl-lib${_d}IXPManager${_d}lib${_d}IXPManager${_d}Config.pm"
    cd "tools${_d}perl-lib${_d}IXPManager"
    perl 'Makefile.PL'
    make install
    sed -e "$sed_perl_config_tweaks" "ixpmanager.conf" >"${etc_dir}${_d}ixpmanager.conf"
    cd "..${_d}..${_d}.."
    chown www-data:www-data "${etc_dir}${_d}ixpmanager.conf"
    chmod u=rw,go= "${etc_dir}${_d}ixpmanager.conf"
fi

if test "$do_integrate_mrtg" -eq 1; then
    warn "integrating mrtg into ixp-manager"
    cd "$repo_dir"
    mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name" <<EOS
UPDATE \`ixp\` SET \`mrtg_path\` = '$mrtg_data_dir';
UPDATE \`ixp\` SET \`mrtg_p2p_path\` = '$mrtg_p2p_path';
EOS
fi

if test "$do_setup_mrtg" -eq 1; then
    warn "setting up mrtg"
    cd "$repo_dir"
    test -z "$mrtg_infra1_aggregate_name" || printf "UPDATE \`infrastructure\` set \`aggregate_graph_name\` = '%s' where \`id\` = '1';\n" "$mrtg_infra1_aggregate_name" | mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name"
    test -z "$mrtg_ixp1_aggregate_name" || printf "UPDATE \`ixp\` set \`aggregate_graph_name\` = '%s' where \`id\` = '1';\n" "$mrtg_ixp1_aggregate_name" | mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name"
    sed_i -e 's:^\( *\)\([^# ]\):#\1\2:' "${cron_dir}${_d}mrtg" # disable default cron job
    sed_i -e 's:^/etc/mrtg.cfg$:/etc/mrtg/mrtg.cfg:' "${etc_dir}/mrtg-rrd.conf"
    killall mrtg 2>$_null || true
    "bin${_d}ixptool.php" -a 'statistics-cli.gen-mrtg-conf'
    cd "$mrtg_data_dir"
    if test -s "$installer_mrtg_file"; then
        tar -x -p -f "$installer_mrtg_file"
    fi
fi

if test "$do_setup_mrtg_init" -eq 1; then
    warn "setting up mrtg init script"
    cd "$repo_dir"
    sed -e "$sed_mrtg_init_tweaks" "tools${_d}runtime${_d}mrtg${_d}ubuntu-mrtg-initd" >"${init_dir}${_d}mrtg"
    chmod +x "${init_dir}${_d}mrtg"
    case "$platform_name" in
    Debian|Ubuntu)
        update-rc.d mrtg defaults
        invoke-rc.d mrtg start
        ;;
    esac
fi

if test "$do_setup_periodic_update" -eq 1; then
    warn "setting up periodic update script"
    cd "$repo_dir"
    cat >"${custom_scripts_dir}${_d}ixpm-periodic-update.sh" <<EOS
#!${_d_esc}bin${_d_esc}sh

PATH="${custom_scripts_dir}:\${PATH}"
dir="$custom_scripts_dir"
APPLICATION_PATH="$repo_dir"

# Synchronise configuration files
"\${APPLICATION_PATH}${_d_esc}bin${_d_esc}ixptool.php" -a 'statistics-cli.gen-mrtg-conf' >$_null_esc 2>&1

# Kick daemons
EOS
    case "$platform_name" in
    Debian|Ubuntu)
        cat >>"${custom_scripts_dir}${_d}ixpm-periodic-update.sh" <<EOS
invoke-rc.d mrtg restart >$_null_esc 2>&1
EOS
        ;;
    esac
    chmod +x "${custom_scripts_dir}${_d}ixpm-periodic-update.sh"
fi

if test "$do_setup_periodic_update_cron" -eq 1; then
    warn "setting up periodic update cron job"
    cd "$repo_dir"
    cat >"${cron_dir}${_d}ixpm-periodic-update" <<EOS
$cron_timedef_periodic_update root "${custom_scripts_dir}${_d_esc}ixpm-periodic-update.sh" >$_null_esc 2>&1
EOS
fi

if test "$do_setup_store_traffic_cron" -eq 1; then
    warn "setting up store-traffic to db cron job"
    cd "$repo_dir"
    cat >"${cron_dir}${_d}ixpm-store-traffic" <<EOS
$cron_timedef_store_traffic root "${repo_dir}${_d}bin${_d}ixptool.php" -a 'statistics-cli.upload-traffic-stats-to-db' >$_null_esc 2>&1
EOS
fi

if test "$do_setup_update_macs" -eq 1; then
    warn "setting up update-macs script"
    cd "$repo_dir"
    cp "tools${_d}runtime${_d}l2database${_d}update-l2database.pl" "${custom_scripts_dir}${_d}ixpm-update-l2database.pl"
    cat >>"${custom_scripts_dir}${_d}ixpm-periodic-update.sh" <<EOS

# Update MAC listings
"\${dir}${_d_esc}ixpm-update-l2database.pl"
EOS
fi

if test "$do_setup_poll_switch_cron" -eq 1; then
    warn "setting up poll-switch cron job"
    cd "$repo_dir"
    cat >"${cron_dir}${_d}ixpm-poll-switch" <<EOS
$cron_timedef_poll_switch root "${repo_dir}${_d_esc}bin${_d_esc}ixptool.php" -a 'switch-cli.snmp-poll' >$_null_esc 2>&1
EOS
fi

if test "$do_install_sflowtool" -eq 1; then
    warn "installing and building sflowtool"
    cd "$repo_dir"
    cd "$custom_src_dir"
    wget "http://www.inmon.com/bin/sflowtool-${sflowtool_version}.tar.gz"
    printf '%s *sflowtool-%s.tar.gz%s' "$sflowtool_sha512" "$sflowtool_version" "${_e}" | sha512sum -c || die "sflowtool package invalid"
    tar -x -z -f "sflowtool-${sflowtool_version}.tar.gz"
    cd "sflowtool-$sflowtool_version"
    .${_d}configure "--prefix=${custom_base_dir}" "--bindir=${custom_scripts_dir}"
    make CFLAGS="$sflowtool_cflags" CPPFLAGS="$sflowtool_cppflags" LDFLAGS="$sflowtool_ldflags"
    make install
    cd ..
    rm -R "sflowtool-$sflowtool_version" "sflowtool-${sflowtool_version}.tar.gz"
fi

if test "$do_setup_rrdcached" -eq 1; then
    warn "setting up and starting rrdcached init script"
    cd "$repo_dir"
    sed_i -e "$sed_rrdcached_config_tweaks" "$rrdcached_config_file"
    case "$platform_name" in
    Debian|Ubuntu)
        invoke-rc.d rrdcached restart
        ;;
    esac
fi

if test "$do_setup_sflow_to_rrd" -eq 1; then
    warn "setting up sflow-to-rrd scripts"
    cd "$repo_dir"
    sed -e "$sed_control_sflow_tweaks" "tools${_d}runtime${_d}sflow${_d}control-sflow-to-rrd-handler" >"${custom_scripts_dir}${_d}control-sflow-to-rrd-handler"
    sed -e "$sed_sflow_handler_tweaks" "tools${_d}runtime${_d}sflow${_d}sflow-to-rrd-handler" >"${custom_scripts_dir}${_d}sflow-to-rrd-handler"
    chmod +x "${custom_scripts_dir}${_d}control-sflow-to-rrd-handler"
    chmod +x "${custom_scripts_dir}${_d}sflow-to-rrd-handler"
    cd "$sflow_rrd_dir"
    if test -s "$installer_sflow_file"; then
        tar -x -p -f "$installer_sflow_file"
    fi
fi

if test "$do_setup_sflow_to_rrd_init" -eq 1; then
    warn "setting up and starting sflow-to-rrd init script"
    cd "$repo_dir"
    case "$platform_name" in
    Debian|Ubuntu)
        cat >"${init_dir}${_d}ixpm-sflow-to-rrd" <<EOS
#!${_d_esc}bin${_d_esc}sh

### BEGIN INIT INFO
# Provides:          ixpm-sflow-to-rrd
# Required-Start:    \$syslog \$remote_fs
# Required-Stop:     \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: sflow-to-rrd control daemon
# Description:       Controller for the sflow-to-rrd daemon.
### END INIT INFO

DIR="$custom_scripts_dir"
if [ -x "${custom_scripts_dir}${_d_esc}control-sflow-to-rrd-handler" ];
then
    "${custom_scripts_dir}${_d_esc}control-sflow-to-rrd-handler" \$1
else
    printf 'Required program "%s${_d_esc}control-sflow-to-rrd-handler" not found!$_e_esc' "${custom_scripts_dir}"
    exit 1
fi
EOS
        chmod +x "${init_dir}${_d}ixpm-sflow-to-rrd"
        update-rc.d ixpm-sflow-to-rrd defaults
        invoke-rc.d ixpm-sflow-to-rrd start
        ;;
    esac
fi

if test "$do_let_sflow_through_firewall" -eq 1; then
    warn "letting sflow through firewall"
    cd "$repo_dir"
    case "$platform_name" in
    Debian|Ubuntu)
        sed_i -e "$sed_sflow_firewall_tweaks" "$firewall_config_file"
        invoke-rc.d ferm restart
        ;;
    esac
fi

if test "$do_integrate_sflow" -eq 1; then
    warn "integrating sflow into ixp-manager"
    cd "$repo_dir"
    sed -e "$sed_sflow_graph_tweaks" "tools/www/sflow-graph.php" >"${web_dir}/sflow/sflow-graph.php"
    chown www-data:www-data "${web_dir}/sflow/sflow-graph.php"
    chmod u=rw,go=r "${web_dir}/sflow/sflow-graph.php"
fi

if test "$do_setup_smokeping" -eq 1; then
    warn "setting up smokeping"
    cd "$repo_dir"
    bin/ixptool.php -a 'smokeping-cli.gen-conf'
    cd "$smokeping_data_dir"
    if test -s "$installer_smokeping_file"; then
        tar -x -p -f "$installer_smokeping_file"
    fi
    cd "$smokeping_image_cache_dir"
    if test -s "$installer_smokeping_images_file"; then
        tar -x -p -f "$installer_smokeping_images_file"
    fi
    invoke-rc.d smokeping restart
fi

if test "$do_integrate_smokeping" -eq 1; then
    warn "integrating smokeping into ixp-manager"
    cd "$repo_dir"
    printf "UPDATE \`ixp\` set \`smokeping\` = '%s/smokeping/smokeping.cgi' where \`id\` = '1';\n" "$site_url" | mysql --default-character-set=utf8 -u "$db_user" "-p$db_pass" "$db_name"
fi

## TODO: further installation steps:
##
##   reseller settings - https://github.com/inex/IXP-Manager/wiki/Reseller-Functionality
##   email notifications - https://github.com/inex/IXP-Manager/wiki/Email-Notifications
##   exporting member details - https://github.com/inex/IXP-Manager/wiki/Exporting-Member-Details
##   other undocumented stuff - read list at bottom of https://github.com/inex/IXP-Manager/wiki/Installation-08-Setting-Up-Your-IXP

if test "$do_remove_build_deps" -eq 1; then
    warn "removing unneeded build-deps"
    cd "$repo_dir"
    case "$platform_name" in
    Debian|Ubuntu)
        for dep in $build_deps; do
            test install = "`dpkg --get-selections $dep | sed -e 's:^.*\t\([^ \t]\+\)$:\1:' || true`" || apt-get -y --auto-remove purge $dep
        done
        ;;
    esac
fi

if test "$do_start_webserver" -eq 1; then
    warn "starting webserver"
    cd "$repo_dir"
    case "$platform_name" in
    Debian|Ubuntu)
        invoke-rc.d apache2 restart
        ;;
    esac
fi

if test "$do_let_web_through_firewall" -eq 1; then
    warn "letting web traffic through firewall"
    cd "$repo_dir"
    sed_i -e "$sed_webserver_firewall_tweaks" "$firewall_config_file"
    case $platform_name in
    Debian|Ubuntu)
        invoke-rc.d ferm restart
        ;;
    esac
fi

if test "$do_setup_maintenance_file" -eq 1; then
    cd "$repo_dir"
    rm MAINT_MODE_ENABLED 2>$_null || true
fi

if test $with_root_db_password -eq 0 && test $do_create_database -eq 1; then
    printf %s%s "The root db user still has no password set. Do that now!" "$_e"
    mysqladmin -u root password
fi
