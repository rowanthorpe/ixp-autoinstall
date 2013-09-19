#!/bin/sh

# NB: This is a work in progress, not yet very portable or trustworthy...
#
# Dumps a mysql db *DATA ONLY, NOT SCHEMA* in the most diff-friendly fashion

## set these
user="root"
dbname="ixp"
needspassword=0
destdir="."
##

servername=`hostname`
timestamp=`date +%Y%m%d`

mysqldump \
  --skip-opt --complete-insert --order-by-primary --skip-comments --no-create-info \
  `test -z "$user" || printf -- '-u %s' "$user"` \
  `test "$needspassword" -eq 0 || printf -- -p` \
    "$dbname" >"${destdir}/mysqldump-${servername}-${dbname}-${timestamp}.sql"
