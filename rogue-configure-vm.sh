#!/bin/bash

# use static ip
#==========================
ROGUE_HOSTNAME=syrus-geonode

#ROGUE_ADDRESS=192.168.10.199
#ROGUE_NETMASK=255.255.255.0
#ROGUE_GATEWAY=192.168.10.1

ROGUE_GEOSERVER_ADMIN_USER=admin
ROGUE_GEOSERVER_ADMIN_PASSWORD=geoserver

ROGUE_DATABASE_ADDRESS=192.168.10.100

#=========================

# use dhcp
#=========================
#ROGUE_HOSTNAME=syrus-geonode
#=========================


##------------- Script Settings
GEONODE_SETTINGS_PATH=/var/lib/geonode/rogue_geonode/rogue_geonode/settings.py
GEOSERVER_GLOBAL_SETTINGS_PATH=/var/lib/geoserver_data/global.xml
NOMINATIM_LOCAL_SETTINGS_PATH=/var/lib/Nominatim/settings/local.php
NOMINATIM_SETTINGS_PATH=/var/lib/Nominatim/settings/settings.php
NOMINATIM_DB_USER=gis_admin
NOMINATIM_DB_PASSWORD=r0gu3
NOMINATIM_DB=ca_nominatim

##----------------------------

# Abort script on any error
set -e

function prompt_to_verify_params(){
    echo ""

    if [ -z "$ROGUE_HOSTNAME" ]; then
        echo "Note: hostname will not be changed as ROGUE_HOSTNAME was not specified."
        echo "      current hostname: '$HOSTNAME'";
    else
        echo "hostname: '$ROGUE_HOSTNAME'";
        echo "current hostname: '$HOSTNAME'";
    fi

    echo ""

    if [ -z "$ROGUE_ADDRESS" ]; then
        if [ -n "$ROGUE_NETMASK" ]; then
            echo "WARNING: ignoring ROGUE_NETMASK since ROGUE_ADDRESS is not set!"
        fi

        if [ -n "$ROGUE_GATEWAY" ]; then
            echo "WARNING: ignoring ROGUE_GATEWAY since ROGUE_ADDRESS is not set!"
        fi

        echo "Note: will use DHCP to get an ip as a specific ROGUE_ADDRESS was not specified";
    else
        if [ -z "$ROGUE_NETMASK" ] || [ -z "$ROGUE_GATEWAY" ]; then
            echo "ERROR: since ROGUE_ADDRESS is specified, ROGUE_NETMASK and ROGUE_GATEWAY must be specified as well.";
            return 1;
        fi

        echo "Note: will use static ip with the following settings"
        echo "    address: '$ROGUE_ADDRESS'";
        echo "    netmask: '$ROGUE_NETMASK'";
        echo "    gateway: '$ROGUE_GATEWAY'";
    fi

    echo ""

    while true; do
        read -p "=> Are the above correct? " yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) echo "    Aborting script!";return 1;;
            * ) echo "    Please answer yes or no.";;
        esac
    done
}

function is_defined(){
    # if these variables are empty or have been set to empty, abort the script
    if [ -z "$1" ]; then
        echo "** Error ** a required variable is not set. Aborting script!";
        return 2;
    fi
}

function file_exists() {
    if [ ! -f $1 ]; then
        echo "Error: file not found! '"$1"'"
        return 1
    fi

    return 0
}

function configure_network_interfaces(){
    echo ""
    echo "Info: configuring network interfaces"
    echo "      backing up /etc/network/interfaces file to /etc/network/interfaces_$ROGUE_DATE.bak"
    mv /etc/network/interfaces "/etc/network/interfaces_$ROGUE_DATE.bak"

    interfaces_header="# This file was generated by ROGUE configuration script.\n\n# The loopback network interface\nauto lo\niface lo inet loopback\n\n# Primary interface\n"

    if [ -n "$ROGUE_ADDRESS" ]; then
        interfaces_content="iface eth0 inet static\naddress $ROGUE_ADDRESS\nnetmask $ROGUE_NETMASK\ngateway $ROGUE_GATEWAY"
    else
        interfaces_content="auto eth0\niface eth0 inet dhcp"
    fi

    echo "      generating /etc/network/interfaces file"
    echo -e $interfaces_header$interfaces_content > '/etc/network/interfaces'
}

function configure_hostname(){
    echo "Info: configuring hostname"
    if [ -z "$ROGUE_HOSTNAME" ]; then
        return
    fi

    echo "      backing up existing /etc/hostname file to /etc/hostname_$ROGUE_DATE.bak"
    file_exists "/etc/hostname"
    mv /etc/hostname "/etc/hostname_$ROGUE_DATE.bak"

    hostname_content="# This file was generated by ROGUE configuration script.\n$ROGUE_HOSTNAME"

    echo "      generating /etc/hostname file"
    echo -e $hostname_content > '/etc/hostname'

    file_exists "/etc/hosts"
    echo "      updating etc/hosts"
    sed -i "s|^127.0.1.1.*|127.0.1.1\t$ROGUE_HOSTNAME|" /etc/hosts
}

function restart_network_interface(){
    echo ""
    echo "Restarting the network interface"
    echo "Note: If you have ssh'd to this vm and another ip is assigned you will be disconnected."

    while true; do
        read -p "=> continue? " yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) echo "    Will not restart network interface.";return;;
            * ) echo "    Please answer yes or no.";;
        esac
    done

    # this (ifdown eth0) will error if currently on dhcp and hence eth0 is not configured, but should come up
    ifdown eth0
    ifup eth0
}

function get_ip_address() {
   ROGUE_CURRENT_ADDRESS=`/sbin/ifconfig | grep '\<inet\>' | sed -n '1p' | tr -s ' ' | cut -d ' ' -f3 | cut -d ':' -f2`
   echo ""
   echo "Info: obtained ip address "$ROGUE_CURRENT_ADDRESS
}

function update_geonode_settings(){
    echo ""
    echo "Info: configuring GeoNode"
    echo "      updating geonode settings file '"$GEONODE_SETTINGS_PATH"'"

    file_exists $GEONODE_SETTINGS_PATH

    # Note: need to use the latest ip after network interface is restarted. Particularly the case when using DHCP
    #       if not using DHCP, we should be able to use ROGUE_ADDRESS even without restarting the network interface
    echo "      setting GeoNode SITE_URL";
    sed -i 's|^SITEURL =.*|SITEURL = "http://'$ROGUE_CURRENT_ADDRESS'/"|' $GEONODE_SETTINGS_PATH

    echo "      setting GeoNode GEOSERVER_BASE_URL";
    sed -i 's|^GEOSERVER_BASE_URL =.*|GEOSERVER_BASE_URL = "http://'$ROGUE_CURRENT_ADDRESS'/geoserver/"|' $GEONODE_SETTINGS_PATH

    echo "      setting geoserver admin credentials used by GeoNode";
    sed -i 's|^GEOSERVER_CREDENTIALS =.*|GEOSERVER_CREDENTIALS = "'$ROGUE_GEOSERVER_ADMIN_USER'","'$ROGUE_GEOSERVER_ADMIN_PASSWORD'"|' $GEONODE_SETTINGS_PATH
}

function update_geoserver_settings(){
    echo ""
    echo "Info: configuring GeoServer"
    echo "      updating geoserver settings file '"$GEOSERVER_GLOBAL_SETTINGS_PATH"'"

    file_exists $GEOSERVER_GLOBAL_SETTINGS_PATH

    echo ""
    echo "      setting GeoServer proxy base URL"
    sed -i 's|^    <proxyBaseUrl>.*|    <proxyBaseUrl>http://'$ROGUE_CURRENT_ADDRESS'/geoserver/</proxyBaseUrl>|' $GEOSERVER_GLOBAL_SETTINGS_PATH
}

function update_nominatim_settings(){
    echo ""
    echo "Info: configuring Nominatim"

    file_exists $NOMINATIM_LOCAL_SETTINGS_PATH

    echo "      updating Nominatim settings file '"$NOMINATIM_LOCAL_SETTINGS_PATH"'"
    sed -i "s|^@define('CONST_Website_BaseURL',.*|@define('CONST_Website_BaseURL', 'http://"$ROGUE_CURRENT_ADDRESS"/');|" $NOMINATIM_LOCAL_SETTINGS_PATH

    echo "      updating Nominatim local settings file '"$NOMINATIM_SETTINGS_PATH"'"
    sed -i "s|^@define('CONST_Database_DSN',.*|@define('CONST_Database_DSN', 'psql://"$NOMINATIM_DB_USER:$NOMINATIM_DB_PASSWORD@$ROGUE_DATABASE_ADDRESS/$NOMINATIM_DB"');|" $NOMINATIM_SETTINGS_PATH
}

function main(){
    ROGUE_DATE=`date +%Y-%m-%d_%H:%M:%S`
    echo "rogue configure vm. date: $ROGUE_DATE"

    prompt_to_verify_params ROGUE_RESULT
    #echo "    result= $ROGUE_RESULT";

    # if a value is returned, stop the script
    if [ -n "$ROGUE_RESULT" ]; then
        echo "ERROR: Exiting scrip due to unexpected result"
        exit $ROGUE_RESULT;
    fi

    # configure hostname
    configure_hostname

    # configure
    configure_network_interfaces

    # restart network interface
    restart_network_interface

    # get the latest ip after restarting network interface.
    # when using DHCP, need to get ip and when static
    get_ip_address


#    geonode settings config has changed and this script doesn't cover it yet
#    things that need to be changed in geonode:
#        in /var/lib/geonode/rogue_geonode/rogue_geonode/settings.py  
#            SITEURL needs to change to point to geonode for example: 192.168.10.134  (note not geoserver)
#        in local_settings.py 
#            all bd username passwords ans url
#            geoserver location <<==== this is the one we must do either way since it i resolved on client
#    update_geonode_settings

    update_geoserver_settings

    update_nominatim_settings
}

#run the main function
main
