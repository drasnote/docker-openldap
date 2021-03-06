#!/bin/bash

### Image Setup
[ -d /assets/state ] || mkdir -p /assets/state/

### Setup OpenLDAP
set -o pipefail

# set -x (bash debug) if log level is trace
# https://github.com/osixia/docker-light-baseimage/blob/stable/image/tool/log-helper
log-helper level eq trace && set -x

# Reduce maximum number of number of open file descriptors to 1024
# otherwise slapd consumes two orders of magnitude more of RAM
# see https://github.com/docker/docker/issues/8231
ulimit -n 1024

LDAP_ETC_DIR="/etc/openldap"
LDAP_RUN_DIR="/var/run/openldap"
LDAP_CONFIG_DIR="$LDAP_ETC_DIR/slapd.d"
LDAP_BACKEND_DIR="/var/lib/openldap"
LDAP_MODULES_DIR="/usr/lib/openldap"
LDAP_RUN_PIDFILE="$LDAP_RUN_DIR/slapd.pid"
LDAP_RUN_ARGSFILE="$LDAP_RUN_DIR/slapd.args"

# create dir if they not already exists
[ -d ${LDAP_ETC_DIR} ] || mkdir -p ${LDAP_ETC_DIR}
[ -d ${LDAP_CONFIG_DIR} ] || mkdir -p ${LDAP_CONFIG_DIR}
[ -d ${LDAP_BACKEND_DIR} ] || mkdir -p ${LDAP_BACKEND_DIR}
[ -d ${LDAP_MODULES_DIR} ] || mkdir -p ${LDAP_MODULES_DIR}
[ -d ${LDAP_RUN_DIR} ] || mkdir -p ${LDAP_RUN_DIR}


# fix file permissions
function fix_file_permissions() {
chown -R ldap:ldap ${LDAP_ETC_DIR} ${LDAP_CONFIG_DIR} ${LDAP_BACKEND_DIR} ${LDAP_MODULES_DIR} ${LDAP_RUN_DIR}
chown -R ldap:ldap /assets/slapd
}

fix_file_permissions


FIRST_START_DONE="/assets/state/slapd-first-start-done"
WAS_STARTED_WITH_TLS="/etc/openldap/slapd.d/docker-openldap-was-started-with-tls"
WAS_STARTED_WITH_TLS_ENFORCE="/etc/openldap/slapd.d/docker-openldap-was-started-with-tls-enforce"
WAS_STARTED_WITH_REPLICATION="/etc/openldap/slapd.d/docker-openldap-was-started-with-replication"

# container first start
if [ ! -e "$FIRST_START_DONE" ]; then

  #
  # Helpers
  #
  function get_ldap_base_dn() {
    # if LDAP_BASE_DN is empty set value from LDAP_DOMAIN
    if [ -z "$LDAP_BASE_DN" ]; then
      IFS='.' read -ra LDAP_BASE_DN_TABLE <<< "$LDAP_DOMAIN"
      for i in "${LDAP_BASE_DN_TABLE[@]}"; do
        EXT="dc=$i,"
        LDAP_BASE_DN=$LDAP_BASE_DN$EXT
      done

      LDAP_BASE_DN=${LDAP_BASE_DN::-1}
    fi

  }

  function is_new_schema() {
    local COUNT=$(ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=schema,cn=config cn | grep -c $1)
    if [ "$COUNT" -eq 0 ]; then
      echo 1
    else
      echo 0
    fi
  }

  #
  # Global variables
  #
  BOOTSTRAP=false

  #
  # database and config directory are empty
  # setup bootstrap config - Part 1
  #
  if [ -z "$(ls -A ${LDAP_BACKEND_DIR} | sed  "s/lost+found//")" ] && [ -z "$(ls -A ${LDAP_CONFIG_DIR} | sed  "s/lost+found//")" ]; then

    BOOTSTRAP=true
    log-helper info "Database and config directory are empty..."
    log-helper info "Init new ldap server..."


mkdir -p ${LDAP_BACKEND_DIR}/run
mkdir -p ${LDAP_BACKEND_DIR}/openldap-data 
chmod -R 700 ${LDAP_BACKEND_DIR}
cp -R /etc/openldap/DB_CONFIG.example ${LDAP_BACKEND_DIR}/openldap-data/DB_CONFIG

LDAP_BACKEND_OBJECTCLASS="olcMdbConfig"

get_ldap_base_dn
LDAP_CONFIG_PASSWORD_ENCRYPTED=$(slappasswd -s $LDAP_CONFIG_PASSWORD)
LDAP_ADMIN_PASSWORD_ENCRYPTED=$(slappasswd -s $LDAP_ADMIN_PASSWORD)

    sed -i "s|{{ LDAP_ETC_DIR }}|${LDAP_ETC_DIR}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_CONFIG_DIR }}|${LDAP_CONFIG_DIR}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_BACKEND_DIR }}|${LDAP_BACKEND_DIR}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_MODULES_DIR }}|${LDAP_MODULES_DIR}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_RUN_PIDFILE }}|${LDAP_RUN_PIDFILE}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_RUN_ARGSFILE }}|${LDAP_RUN_ARGSFILE}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif

    sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_BACKEND_OBJECTCLASS }}|${LDAP_BACKEND_OBJECTCLASS}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif

    sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif

    sed -i "s|{{ LDAP_CONFIG_PASSWORD_ENCRYPTED }}|${LDAP_CONFIG_PASSWORD_ENCRYPTED}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif
    sed -i "s|{{ LDAP_ADMIN_PASSWORD_ENCRYPTED }}|${LDAP_ADMIN_PASSWORD_ENCRYPTED}|g" /assets/slapd/config/bootstrap/ldif/00-slapd.ldif


    slapadd -n0 -F ${LDAP_CONFIG_DIR} -l  /assets/slapd/config/bootstrap/ldif/00-slapd.ldif 2>&1 | log-helper debug

#ETC_HOSTS=$(cat /etc/hosts | sed "/$HOSTNAME/d")
#echo "0.0.0.0 $HOSTNAME" > /etc/hosts
#echo "$ETC_HOSTS" >> /etc/hosts


  #
  # Error: the database directory is empty but not the config directory
  #
  elif [ -z "$(ls -A ${LDAP_BACKEND_DIR} | sed  "s/lost+found//")" ] && [ ! -z "$(ls -A ${LDAP_CONFIG_DIR} | sed  "s/lost+found//")" ]; then
    log-helper error "Error: the database directory (${LDAP_BACKEND_DIR}) is empty but not the config directory (${LDAP_CONFIG_DIR})"
    exit 1

  #
  # Error: the config directory is empty but not the database directory
  #
  elif [ ! -z "$(ls -A ${LDAP_BACKEND_DIR} | sed  "s/lost+found//")" ] && [ -z "$(ls -A ${LDAP_CONFIG_DIR} | sed  "s/lost+found//")" ]; then
    log-helper error "Error: the config directory (${LDAP_CONFIG_DIR}) is empty but not the database directory (${LDAP_BACKEND_DIR})"
    exit 1
  fi


  #
  # start OpenLDAP
  #

  # get previous hostname if OpenLDAP was started with replication
  # to avoid configuration pbs
  PREVIOUS_HOSTNAME_PARAM=""
  if [ -e "$WAS_STARTED_WITH_REPLICATION" ]; then

    source $WAS_STARTED_WITH_REPLICATION

    # if previous hostname != current hostname
    # set previous hostname to a loopback ip in /etc/hosts
    if [ "$PREVIOUS_HOSTNAME" != "$HOSTNAME" ]; then
      echo "127.0.0.2 $PREVIOUS_HOSTNAME" >> /etc/hosts
      PREVIOUS_HOSTNAME_PARAM="ldap://$PREVIOUS_HOSTNAME"
    fi
  fi

  # if the config was bootstraped with TLS
  # we create fake temporary certificates if they do not exist
  if [ -e "$WAS_STARTED_WITH_TLS" ]; then
    source $WAS_STARTED_WITH_TLS

    log-helper debug "Check previous TLS certificates..."

    [[ -z "$PREVIOUS_LDAP_TLS_CA_CRT_PATH" ]] && PREVIOUS_LDAP_TLS_CA_CRT_PATH="/assets/slapd/certs/$LDAP_TLS_CA_CRT_FILENAME"
    [[ -z "$PREVIOUS_LDAP_TLS_CRT_PATH" ]] && PREVIOUS_LDAP_TLS_CRT_PATH="/assets/slapd/certs/$LDAP_TLS_CRT_FILENAME"
    [[ -z "$PREVIOUS_LDAP_TLS_KEY_PATH" ]] && PREVIOUS_LDAP_TLS_KEY_PATH="/assets/slapd/certs/$LDAP_TLS_KEY_FILENAME"
    [[ -z "$PREVIOUS_LDAP_TLS_DH_PARAM_PATH" ]] && PREVIOUS_LDAP_TLS_DH_PARAM_PATH="/assets/slapd/certs/dhparam.pem"

    ssl-helper $LDAP_SSL_HELPER_PREFIX $PREVIOUS_LDAP_TLS_CRT_PATH $PREVIOUS_LDAP_TLS_KEY_PATH $PREVIOUS_LDAP_TLS_CA_CRT_PATH
    [ -f ${PREVIOUS_LDAP_TLS_DH_PARAM_PATH} ] || openssl dhparam -out ${LDAP_TLS_DH_PARAM_PATH} 2048

    chmod 600 ${PREVIOUS_LDAP_TLS_DH_PARAM_PATH}
    chown ldap:ldap $PREVIOUS_LDAP_TLS_CRT_PATH $PREVIOUS_LDAP_TLS_KEY_PATH $PREVIOUS_LDAP_TLS_CA_CRT_PATH $PREVIOUS_LDAP_TLS_DH_PARAM_PATH
  fi

  # start OpenLDAP
  log-helper info "Start OpenLDAP (Initialization...)"
  fix_file_permissions
  if log-helper level ge debug; then
    # debug
    slapd -h "ldap://localhost ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL 2>&1 &
    #slapd -h "ldap://$HOSTNAME $PREVIOUS_HOSTNAME_PARAM ldap://localhost ldapi:///" -u openldap -g openldap -d $LDAP_LOG_LEVEL 2>&1 &
  else
    slapd -h "ldap://localhost ldapi:///" -u ldap -g ldap
    #slapd -h "ldap://$HOSTNAME $PREVIOUS_HOSTNAME_PARAM ldap://localhost ldapi:///" -u openldap -g openldap
  fi

#  if log-helper level ge debug; then
    # debug
#    slapd -h "ldap://$HOSTNAME $PREVIOUS_HOSTNAME_PARAM ldap://localhost ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL 2>&1 &
#  else
#    slapd -h "ldap://$HOSTNAME $PREVIOUS_HOSTNAME_PARAM ldap://localhost ldapi:///" -u ldap -g ldap
#  fi


  log-helper info "Waiting for OpenLDAP to start..."
  
  while [ ! -e ${LDAP_RUN_PIDFILE} ]; do sleep 0.1; done

  #
  # setup bootstrap config - Part 2
  #
  if $BOOTSTRAP; then

    log-helper info "First Time Install - Add bootstrap schemas..."

    # add ppolicy schema
    echo "Adding PPolicy Schema.."
    ldapadd -c -Y EXTERNAL -Q -H ldapi:/// -f /etc/openldap/schema/ppolicy.ldif 2>&1 | log-helper debug

    # convert schemas to ldif
    echo "Convert Schemas to LDIF.."
    SCHEMAS=""
    for f in $(find /assets/slapd/config/bootstrap/schema -name \*.schema -type f); do
      SCHEMAS="$SCHEMAS ${f}"
    done
    /assets/slapd/schema-to-ldif.sh "$SCHEMAS"

    # add converted schemas
    echo "Adding Converted Schemas.."
    for f in $(find /assets/slapd/config/bootstrap/schema -name \*.ldif -type f); do
      log-helper debug "Processing file ${f}"
      # add schema if not already exists
      SCHEMA=$(basename "${f}" .ldif)
      ADD_SCHEMA=$(is_new_schema $SCHEMA)
      if [ "$ADD_SCHEMA" -eq 1 ]; then
        ldapadd -c -Y EXTERNAL -Q -H ldapi:/// -f $f 2>&1 | log-helper debug
      else
        log-helper info "schema ${f} already exists"
      fi
    done

    # set config password
    echo "Setting Config Password.."
    LDAP_CONFIG_PASSWORD_ENCRYPTED=$(slappasswd -s $LDAP_CONFIG_PASSWORD)
    sed -i "s|{{ LDAP_CONFIG_PASSWORD_ENCRYPTED }}|${LDAP_CONFIG_PASSWORD_ENCRYPTED}|g" /assets/slapd/config/bootstrap/ldif/01-config-password.ldif


    # adapt security config file
    echo "Setting Security.."
    get_ldap_base_dn
    sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" /assets/slapd/config/bootstrap/ldif/01-security.ldif

    # process config files (*.ldif) in bootstrap directory (do no process files in subdirectories)
    log-helper info "Add bootstrap ldif..."
    for f in $(find /assets/slapd/config/bootstrap/ldif -mindepth 1 -maxdepth 1 -type f -name \*.ldif  | sort); do
      log-helper debug "Processing file ${f}"
      sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" $f
      sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" $f
      ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f $f 2>&1 | log-helper debug || ldapmodify -h localhost -p 389 -D cn=admin,$LDAP_BASE_DN -w $LDAP_ADMIN_PASSWORD -f $f 2>&1 | log-helper debug
    done

    # read only user
    if [ "${LDAP_READONLY_USER,,}" == "true" ]; then

      log-helper info "First Time Install - Add read only user..."

      LDAP_READONLY_USER_PASSWORD_ENCRYPTED=$(slappasswd -s $LDAP_READONLY_USER_PASSWORD)
      sed -i "s|{{ LDAP_READONLY_USER_USERNAME }}|${LDAP_READONLY_USER_USERNAME}|g" /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user.ldif
      sed -i "s|{{ LDAP_READONLY_USER_PASSWORD_ENCRYPTED }}|${LDAP_READONLY_USER_PASSWORD_ENCRYPTED}|g" /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user.ldif
      sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user.ldif

      sed -i "s|{{ LDAP_READONLY_USER_USERNAME }}|${LDAP_READONLY_USER_USERNAME}|g" /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user-acl.ldif
      sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user-acl.ldif

      sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user-acl.ldif

      log-helper debug "Processing file /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user.ldif"
      ldapmodify -h localhost -p 389 -D cn=admin,$LDAP_BASE_DN -w $LDAP_ADMIN_PASSWORD -f /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user.ldif 2>&1 | log-helper debug

      log-helper debug "Processing file /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user-acl.ldif"
      ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/bootstrap/ldif/readonly-user/readonly-user-acl.ldif 2>&1 | log-helper debug

    fi
  fi

  #
  # TLS config
  #
  if [ -e "$WAS_STARTED_WITH_TLS" ] && [ "${LDAP_TLS,,}" != "true" ]; then
    log-helper error "/!\ WARNING: LDAP_TLS=false but the container was previously started with LDAP_TLS=true"
    log-helper error "TLS can't be disabled once added. Ignoring LDAP_TLS=false."
    LDAP_TLS=true
  fi

  if [ -e "$WAS_STARTED_WITH_TLS_ENFORCE" ] && [ "${LDAP_TLS_ENFORCE,,}" != "true" ]; then
    log-helper error "/!\ WARNING: LDAP_TLS_ENFORCE=false but the container was previously started with LDAP_TLS_ENFORCE=true"
    log-helper error "TLS enforcing can't be disabled once added. Ignoring LDAP_TLS_ENFORCE=false."
    LDAP_TLS_ENFORCE=true
  fi

  if [ "${LDAP_TLS,,}" == "true" ]; then

    log-helper info "Add TLS config..."

    LDAP_TLS_CA_CRT_PATH="/assets/slapd/certs/$LDAP_TLS_CA_CRT_FILENAME"
    LDAP_TLS_CRT_PATH="/assets/slapd/certs/$LDAP_TLS_CRT_FILENAME"
    LDAP_TLS_KEY_PATH="/assets/slapd/certs/$LDAP_TLS_KEY_FILENAME"
    LDAP_TLS_DH_PARAM_PATH="/assets/slapd/certs/dhparam.pem"

    # generate a certificate and key with ssl-helper tool if LDAP_CRT and LDAP_KEY files don't exists
    # https://github.com/osixia/docker-light-baseimage/blob/stable/image/service-available/:ssl-tools/assets/tool/ssl-helper
    ssl-helper $LDAP_SSL_HELPER_PREFIX $LDAP_TLS_CRT_PATH $LDAP_TLS_KEY_PATH $LDAP_TLS_CA_CRT_PATH

    # create DHParamFile if not found
    [ -f ${LDAP_TLS_DH_PARAM_PATH} ] || openssl dhparam -out ${LDAP_TLS_DH_PARAM_PATH} 2048
    chmod 600 ${LDAP_TLS_DH_PARAM_PATH}

    # fix file permissions
    chown -R ldap:ldap /assets/slapd

    # adapt tls ldif
    sed -i "s|{{ LDAP_TLS_CA_CRT_PATH }}|${LDAP_TLS_CA_CRT_PATH}|g" /assets/slapd/config/tls/tls-enable.ldif
    sed -i "s|{{ LDAP_TLS_CRT_PATH }}|${LDAP_TLS_CRT_PATH}|g" /assets/slapd/config/tls/tls-enable.ldif
    sed -i "s|{{ LDAP_TLS_KEY_PATH }}|${LDAP_TLS_KEY_PATH}|g" /assets/slapd/config/tls/tls-enable.ldif
    sed -i "s|{{ LDAP_TLS_DH_PARAM_PATH }}|${LDAP_TLS_DH_PARAM_PATH}|g" /assets/slapd/config/tls/tls-enable.ldif

    sed -i "s|{{ LDAP_TLS_CIPHER_SUITE }}|${LDAP_TLS_CIPHER_SUITE}|g" /assets/slapd/config/tls/tls-enable.ldif
    sed -i "s|{{ LDAP_TLS_VERIFY_CLIENT }}|${LDAP_TLS_VERIFY_CLIENT}|g" /assets/slapd/config/tls/tls-enable.ldif

    ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/tls/tls-enable.ldif 2>&1 | log-helper debug

    [[ -f "$WAS_STARTED_WITH_TLS" ]] && rm -f "$WAS_STARTED_WITH_TLS"
    echo "export PREVIOUS_LDAP_TLS_CA_CRT_PATH=${LDAP_TLS_CA_CRT_PATH}" > $WAS_STARTED_WITH_TLS
    echo "export PREVIOUS_LDAP_TLS_CRT_PATH=${LDAP_TLS_CRT_PATH}" >> $WAS_STARTED_WITH_TLS
    echo "export PREVIOUS_LDAP_TLS_KEY_PATH=${LDAP_TLS_KEY_PATH}" >> $WAS_STARTED_WITH_TLS
    echo "export PREVIOUS_LDAP_TLS_DH_PARAM_PATH=${LDAP_TLS_DH_PARAM_PATH}" >> $WAS_STARTED_WITH_TLS

    # ldap client config
    sed -i --follow-symlinks "s,TLS_CACERT.*,TLS_CACERT ${LDAP_TLS_CA_CRT_PATH},g" /etc/openldap/ldap.conf
    echo "TLS_REQCERT ${LDAP_TLS_VERIFY_CLIENT}" >> /etc/openldap/ldap.conf
    cp -f /etc/openldap/ldap.conf /assets/slapd/ldap.conf

    [[ -f "$HOME/.ldaprc" ]] && rm -f $HOME/.ldaprc
    echo "TLS_CERT ${LDAP_TLS_CRT_PATH}" > $HOME/.ldaprc
    echo "TLS_KEY ${LDAP_TLS_KEY_PATH}" >> $HOME/.ldaprc
    cp -f $HOME/.ldaprc /assets/slapd/.ldaprc

    # enforce TLS
    if [ "${LDAP_TLS_ENFORCE,,}" == "true" ]; then
      log-helper info "Add enforce TLS..."
      ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/tls/tls-enforce-enable.ldif 2>&1 | log-helper debug
      touch $WAS_STARTED_WITH_TLS_ENFORCE

    # disable tls enforcing (not possible for now)
    #else
      #log-helper info "Disable enforce TLS..."
      #ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/tls/tls-enforce-disable.ldif 2>&1 | log-helper debug || true
      #[[ -f "$WAS_STARTED_WITH_TLS_ENFORCE" ]] && rm -f "$WAS_STARTED_WITH_TLS_ENFORCE"
    fi

  # disable tls (not possible for now)
  #else
    #log-helper info "Disable TLS config..."
    #ldapmodify -c -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/tls/tls-disable.ldif 2>&1 | log-helper debug || true
    #[[ -f "$WAS_STARTED_WITH_TLS" ]] && rm -f "$WAS_STARTED_WITH_TLS"
  fi



  #
  # Replication config
  #

  function disableReplication() {
    sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" /assets/slapd/config/replication/replication-disable.ldif
    ldapmodify -c -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/replication/replication-disable.ldif 2>&1 | log-helper debug || true
    [[ -f "$WAS_STARTED_WITH_REPLICATION" ]] && rm -f "$WAS_STARTED_WITH_REPLICATION"
  }

  if [ "${LDAP_REPLICATION,,}" == "true" ]; then

    log-helper info "Add replication config..."
    disableReplication || true

    i=1
    for host in $(complex-bash-env iterate LDAP_REPLICATION_HOSTS)
    do
      sed -i "s|{{ LDAP_REPLICATION_HOSTS }}|olcServerID: $i ${!host}\n{{ LDAP_REPLICATION_HOSTS }}|g" /assets/slapd/config/replication/replication-enable.ldif
      sed -i "s|{{ LDAP_REPLICATION_HOSTS_CONFIG_SYNC_REPL }}|olcSyncRepl: rid=00$i provider=${!host} ${LDAP_REPLICATION_CONFIG_SYNCPROV}\n{{ LDAP_REPLICATION_HOSTS_CONFIG_SYNC_REPL }}|g" /assets/slapd/config/replication/replication-enable.ldif
      sed -i "s|{{ LDAP_REPLICATION_HOSTS_DB_SYNC_REPL }}|olcSyncRepl: rid=10$i provider=${!host} ${LDAP_REPLICATION_DB_SYNCPROV}\n{{ LDAP_REPLICATION_HOSTS_DB_SYNC_REPL }}|g" /assets/slapd/config/replication/replication-enable.ldif

      ((i++))
    done

    get_ldap_base_dn
    sed -i "s|\$LDAP_BASE_DN|$LDAP_BASE_DN|g" /assets/slapd/config/replication/replication-enable.ldif
    sed -i "s|\$LDAP_ADMIN_PASSWORD|$LDAP_ADMIN_PASSWORD|g" /assets/slapd/config/replication/replication-enable.ldif
    sed -i "s|\$LDAP_CONFIG_PASSWORD|$LDAP_CONFIG_PASSWORD|g" /assets/slapd/config/replication/replication-enable.ldif

    sed -i "/{{ LDAP_REPLICATION_HOSTS }}/d" /assets/slapd/config/replication/replication-enable.ldif
    sed -i "/{{ LDAP_REPLICATION_HOSTS_CONFIG_SYNC_REPL }}/d" /assets/slapd/config/replication/replication-enable.ldif
    sed -i "/{{ LDAP_REPLICATION_HOSTS_DB_SYNC_REPL }}/d" /assets/slapd/config/replication/replication-enable.ldif

    sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" /assets/slapd/config/replication/replication-enable.ldif

    ldapmodify -c -Y EXTERNAL -Q -H ldapi:/// -f /assets/slapd/config/replication/replication-enable.ldif 2>&1 | log-helper debug || true

    [[ -f "$WAS_STARTED_WITH_REPLICATION" ]] && rm -f "$WAS_STARTED_WITH_REPLICATION"
    echo "export PREVIOUS_HOSTNAME=${HOSTNAME}" > $WAS_STARTED_WITH_REPLICATION

  else

    log-helper info "Disable replication config..."
    disableReplication || true

  fi

  # stop OpenLDAP
    log-helper info "Stop OpenLDAP..."

  SLAPD_PID=$(cat ${LDAP_RUN_PIDFILE})
  kill -15 $SLAPD_PID
  while [ -e /proc/$SLAPD_PID ]; do sleep 0.1; done # wait until slapd is terminated

  # remove config files
  if [ "${LDAP_REMOVE_CONFIG_AFTER_SETUP,,}" == "true" ]; then
    log-helper info "Remove config files..."
    rm -rf /assets/slapd/config
  fi


  # setup done :)
  log-helper info "First start is done..."
  touch $FIRST_START_DONE
fi

ln -sf /assets/slapd/.ldaprc $HOME/.ldaprc
ln -sf /assets/slapd/ldap.conf /etc/openldap/ldap.conf

# force OpenLDAP to listen on all interfaces
ETC_HOSTS=$(cat /etc/hosts | sed "/$HOSTNAME/d")
echo "0.0.0.0 $HOSTNAME" > /etc/hosts
echo "$ETC_HOSTS" >> /etc/hosts



### Setup Backup

  sed -i -e "s/<LDAP_BACKUP_CONFIG_CRON_PERIOD>/$LDAP_BACKUP_CONFIG_CRON_PERIOD/g" /assets/cron/crontab.txt
  sed -i -e "s/<LDAP_BACKUP_DATA_CRON_PERIOD>/$LDAP_BACKUP_DATA_CRON_PERIOD/g" /assets/cron/crontab.txt
  sed -i -e "s/<ZABBIX_HOSTNAME>/$ZABBIX_HOSTNAME/g" /assets/cron/crontab.txt

###
echo 'Starting OpenLDAP Container......'

### Cron
echo 'Starting Cron..'
crontab /assets/cron/crontab.txt


### Nginx
echo 'Starting Nginx..'
#nginx

### OpenLDAP
echo 'Starting OpenLDAP..'
ulimit -n 1024
/usr/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL

