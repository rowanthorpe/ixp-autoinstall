#!/bin/sh

# Copyright (C) 2013 Rowan Thorpe
# All Rights Reserved.
#
# This file is part of ixpm-autoinstall.
#
# ixpm-autoinstall is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, version v2.0 of the License.
#
# ixpm-autoinstall is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License v2.0
# along with ixpm-autoinstall. If not, see:
#
# http://www.gnu.org/licenses/gpl-2.0.html
#
# ixpm-autoinstall is for automating the install/update process for INEX's
# IXP-Manager - https://github.com/inex/IXP-Manager
# It initially derived heavily from the manual install instructions provided there.

# NB: This autoupdater (wrapper around the autoinstaller to update a running version) is much more of a
#     work in progress, far less portable and not very trustworthy yet...
#
# TODO:
#  * get values from conf file instead of hardcoded
#  * make portable (externalize $_d, $_e, $_null, sed_i(), mkdir_p()
#    from ixpm-autoinstall.sh and source them here and in that script)

# Wrapper for ixpm-autoinstall to update a running installation
# (stopping daemons and backing up original files and db first)

set -e

## edit these vars
ixp_backuproot=/root/ixp-old-version
ixp_dbname=ixp
ixp_daemons_to_stop=\
  mrtg \
  smokeping \
  ixpm-sflow-to-rrd \
  rrdcached
ixp_paths_to_backup=\
  /etc/ixpmanager.conf /etc/cron.d/ixpm-* /etc/init.d/ixpm-* \
  /opt/ixpmanager/* /usr/local/bin/ixpm-* /var/log/ixpmanager/* /var/cache/ixpmanager/* \
  /usr/local/share/perl/*/IXPManager/* \
  /etc/mrtg/* /var/lib/mrtg/* \
  /usr/local/bin/sflowtool /usr/local/bin/control-sflow-to-rrd-handler /usr/local/bin/sflow-to-rrd-handler \
  /var/lib/flows/RRDs/* \
  /var/lib/rrdcached/* \
  /var/lib/smokeping/* /var/cache/smokeping/* \
  /etc/apache2/sites-enabled /etc/apache2/sites-available \
  /var/www/* \
  /etc/ferm/ferm.conf
##

## backup
ixp_timestamp=`date +%Y%m%d%H%M%S`
ixp_backupdir="${ixp_backuproot}_$ixp_timestamp"
for x in $ixp_daemons_to_stop; do
    invoke-rc.d $x stop || true
done
for x in $ixp_paths_to_backup; do
    mkdir -p "${ixp_backupdir}$(dirname "$x")"
    cp -axiv "$x" "${ixp_backupdir}$x)"
done
# start in reverse order as they stopped
for x in `printf %s "$ixp_daemons_to_stop" | tr ' ' '\n' | sed -n '1!G;h;$p' | tr '\n' ' '`; do
    invoke-rc.d $x start || true
done
invoke-rc.d rrdcached start || true
invoke-rc.d ixpm-sflow-to-rrd start || true
invoke-rc.d smokeping start || true
invoke-rc.d mrtg start || true
mysqldump -c --default-character-set=utf8 "$ixp_dbname" >"${ixp_backupdir}/ixpmanager-db-dump.sql"
mysql --default-character-set=utf8 -e 'drop database "$ixp_dbname"'

## update
./ixpm-autoinstall.sh \
  --no-setup-webserver \
  --no-let-sflow-through-firewall \
  --no-start-webserver \
  --no-let-web-through-firewall
