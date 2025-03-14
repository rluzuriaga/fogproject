#!/bin/bash
#
#  FOG - Free, Open-Source Ghost is a computer imaging solution.
#  Copyright (C) 2007  Chuck Syperski & Jian Zhang
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#    any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
dots() {
    local pad=$(printf "%0.1s" "."{1..60})
    printf " * %s%*.*s" "$1" 0 $((60-${#1})) "$pad"
    return 0
}
backupReports() {
    dots "Backing up user reports"
    [[ ! -d ../rpttmp/ ]] && mkdir ../rpttmp/ >>$error_log
    [[ -d $webdirdest/management/reports/ ]] && cp -a $webdirdest/management/reports/* ../rpttmp/ >>$error_log
    echo "Done"
    return 0
}
checkDatabaseConnection() {
    dots "Checking connection to master database"
    [[ -n $snmysqlhost ]] && host="--host=$snmysqlhost"
    sqloptionsuser="${host} -s --user=${snmysqluser}"
    mysql $sqloptionsuser --password="${snmysqlpass}" --execute="quit" >/dev/null 2>&1
    errorStat $?
}
registerStorageNode() {
    [[ -z $webroot ]] && webroot="/"
    dots "Checking if this node is registered"
    storageNodeExists=$(wget --no-check-certificate -qO - ${httpproto}://${ipaddress}${webroot}/maintenance/check_node_exists.php --post-data="ip=${ipaddress}")
    echo "Done"
    if [[ $storageNodeExists != exists ]]; then
        [[ -z $maxClients ]] && maxClients=10
        dots "Node being registered"
        curl -s -k -X POST -d "newNode" -d "name=$(echo -n $ipaddress|base64)" -d "path=$(echo -n $storageLocation|base64)" -d "ftppath=$(echo -n $storageLocation|base64)" -d "snapinpath=$(echo -n $snapindir|base64)" -d "sslpath=$(echo -n $sslpath|base64)" -d "ip=$(echo -n $ipaddress|base64)" -d "maxClients=$(echo -n $maxClients|base64)" -d "user=$(echo -n $username|base64)" --data-urlencode "pass=$(echo -n $password|base64)" -d "interface=$(echo -n $interface|base64)" -d "bandwidth=1" -d "webroot=$(echo -n $webroot|base64)" -d "fogverified" ${httpproto}://${ipaddress}${webroot}/maintenance/create_update_node.php
        echo "Done"
    else
        echo " * Node is registered"
    fi
}
updateStorageNodeCredentials() {
    [[ -z $webroot ]] && webroot="/"
    dots "Ensuring node username and passwords match"
    curl -s -k -X POST -d "nodePass" -d "ip=$(echo -n $ipaddress|base64)" -d "user=$(echo -n $username|base64)" --data-urlencode "pass=$(echo -n $password|base64)" -d "fogverified" $httpproto://$ipaddress${webroot}maintenance/create_update_node.php
    echo "Done"
}
backupDB() {
    dots "Backing up database"
    if [[ -d $backupPath/fog_web_${version}.BACKUP ]]; then
        [[ ! -d $backupPath/fogDBbackups ]] && mkdir -p $backupPath/fogDBbackups >>$error_log 2>&1
        wget --no-check-certificate -O $backupPath/fogDBbackups/fog_sql_${version}_$(date +"%Y%m%d_%I%M%S").sql "${httpproto}://${ipaddress}${webroot}/maintenance/backup_db.php" --post-data="type=sql&fogajaxonly=1" >>$error_log 2>&1
    fi
    if [[ $? -ne 0 ]]; then
        echo "Failed"
        if [[ -z $autoaccept ]]; then
            echo
            echo "    We were not able to backup the current database! Just press"
            echo "    [Enter] to proceed anyway or Ctrl+C to stop the installer."
            read
        fi
    else
        echo "Done"
    fi
}
updateDB() {
    case $dbupdate in
        [Yy]|[Yy][Ee][Ss])
            dots "Updating Database"
            local replace='s/[]"\/$&*.^|[]/\\&/g'
            local escstorageLocation=$(echo $storageLocation | sed -e $replace)
            sed -i -e "s/'\/images\/'/'$escstorageLocation'/g" $webdirdest/commons/schema.php
            wget --no-check-certificate -qO - --post-data="confirm&fogverified" --no-proxy ${httpproto}://${ipaddress}${webroot}management/index.php?node=schema >>$error_log 2>&1
            errorStat $?
            ;;
        *)
            echo
            echo " * You still need to install/update your database schema."
            echo " * This can be done by opening a web browser and going to:"
            echo
            echo "   $httpproto://${ipaddress}/fog/management"
            echo
            read -p " * Press [Enter] key when database is updated/installed."
            echo
            ;;
    esac
    dots "Update fogstorage database password"
    mysql $sqloptionsuser --password="${snmysqlpass}" --execute="INSERT INTO globalSettings (settingKey, settingDesc, settingValue, settingCategory) VALUES ('FOG_STORAGENODE_MYSQLPASS', 'This setting defines the password the storage nodes should use to connect to the fog server.', \"$snmysqlstoragepass\", 'FOG Storage Nodes') ON DUPLICATE KEY UPDATE settingValue=\"$snmysqlstoragepass\"" $mysqldbname >>$error_log 2>&1
    errorStat $?
    dots "Granting access to fogstorage database user"
    mysql ${host} -s --user=fogstorage --password="${snmysqlstoragepass}" --execute="INSERT INTO $mysqldbname.taskLog VALUES ( 0, '999test', 3, '127.0.0.1', NOW(), 'fog');" >/dev/null 2>&1
    connect_as_fogstorage=$?
    if [[ $connect_as_fogstorage -eq 0 ]]; then
        mysql $sqloptionsuser --password="${snmysqlpass}" --execute="DELETE FROM $mysqldbname.taskLog WHERE taskID='999test' AND ip='127.0.0.1';" >/dev/null 2>&1
        echo "Skipped"
        return
    fi

    # we still need to grant access for the fogstorage DB user
    # and therefore need root DB access
    mysql $sqloptionsroot --password="${snmysqlrootpass}" --execute="quit" >>$error_log 2>&1
    if [[ $? -ne 0 ]]; then
        echo
        echo "   To improve the overall security the installer will restrict"
        echo "   permissions for the *fogstorage* database user."
        echo "   Please provide the database *root* user password. Be asured"
        echo "   that this password will only be used while the FOG installer"
        echo -n "   is running and won't be stored anywhere: "
        read -rs snmysqlrootpass
        echo
        echo
        mysql $sqloptionsroot --password="${snmysqlrootpass}" --execute="quit" >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo "   Unable to connect to the database using the given password!"
            echo -n "   Try again: "
            read -rs snmysqlrootpass
            mysql $sqloptionsroot --password="${snmysqlrootpass}" --execute="quit" >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                echo
                echo "   Failed! Terminating installer now."
                exit 1
            fi
        fi
    fi
    [[ ! -d ../tmp/ ]] && mkdir -p ../tmp/ >/dev/null 2>&1
    cat >../tmp/fog-db-grant-fogstorage-access.sql <<EOF
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='ANSI' ;
GRANT SELECT ON $mysqldbname.* TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.hosts TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.inventory TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.multicastSessions TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.multicastSessionsAssoc TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.nfsGroupMembers TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.tasks TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.taskStates TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.taskLog TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.snapinTasks TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.snapinJobs TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $mysqldbname.imagingLog TO 'fogstorage'@'%' ;
FLUSH PRIVILEGES ;
SET SQL_MODE=@OLD_SQL_MODE ;
EOF
    mysql $sqloptionsroot --password="${snmysqlrootpass}" <../tmp/fog-db-grant-fogstorage-access.sql >>$error_log 2>&1
    errorStat $?
}
validip() {
    local ip=$1
    local stat=1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    echo $stat
}
getCidr() {
    local cidr
    cidr=$(ip -f inet -o addr | grep $1 | awk -F'[ /]+' '/global/ {print $5}' | head -n2 | tail -n1)
    echo $cidr
}
mask2cidr() {
    local submask=$1
    nbits=0
    OIFS=$IFS
    IFS='.'
    for dec in $submask; do
        case $dec in
            255)
                let nbits+=8
                ;;
            254)
                let nbits+=7
                break
                ;;
            252)
                let nbits+=6
                break
                ;;
            248)
                let nbits+=5
                break
                ;;
            240)
                let nbits+=4
                break
                ;;
            224)
                let
                nbits+=3
                break
                ;;
            192)
                let nbits+=2
                break
                ;;
            128)
                let nbits+=1
                break
                ;;
            0)
                ;;
            *)
                echo "Error: $dec is not recognized"
                exit 1
                ;;
        esac
    done
    IFS=$OIFS
    echo "$nbits"
}
cidr2mask() {
    local i=""
    local mask=""
    local full_octets=$(($1/8))
    local partial_octet=$(($1%8))
    for ((i=0;i<4;i+=1)); do
        if [[ $i -lt $full_octets ]]; then
            mask+=255
        elif [[ $i -eq $full_octets ]]; then
            mask+=$((256 - 2**(8-$partial_octet)))
        else
            mask+=0
        fi
        test $i -lt 3 && mask+=.
    done
    echo $mask
}
mask2network() {
    OIFS=$IFS
    IFS='.'
    read -r i1 i2 i3 i4 <<< "$1"
    read -r m1 m2 m3 m4 <<< "$2"
    IFS=$OIFS
    printf "%d.%d.%d.%d\n"  "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))"
}
interface2broadcast() {
    local interface=$1
    if [[ -z $interface ]]; then
        echo "No interface passed"
        return 1
    fi
    echo $(ip -4 addr show $interface | grep -oP 'brd \K\S+')
}
subtract1fromAddress() {
    local ip=$1
    if [[ -z $ip ]]; then
        echo "No IP Passed"
        return 1
    fi
    if [[ ! $(validip $ip) -eq 0 ]]; then
        echo "Invalid IP Passed"
        return 1
    fi
    oIFS=$IFS
    IFS='.'
    read ip1 ip2 ip3 ip4 <<< "$ip"
    IFS=$oIFS
    if [[ $ip4 -gt 0 ]]; then
        let ip4-=1
    elif [[ $ip3 -gt 0 ]]; then
        let ip3-=1
        ip4=255
    elif [[ $ip2 -gt 0 ]]; then
        let ip2-=1
        ip3=255
        ip4=255
    elif [[ $ip1 -gt 0 ]]; then
        let ip1-=1
        ip2=255
        ip3=255
        ip4=255
    else
        echo "Invalid IP ranges were passed"
        echo ${ip1}.${ip2}.${ip3}.${ip4}
        return 2
    fi
    echo ${ip1}.${ip2}.${ip3}.${ip4}
}
subtractFromAddress() {
    local ipaddress="$1"
    local decreaseby=$2
    local maxOctetValue=256
    local octet1=""
    local octet2=""
    local octet3=""
    local octet4=""
    oIFS=$IFS
    IFS='.' read octet1 octet2 octet3 octet4 <<< "$ipaddress"
    IFS=$oIFS
    let octet4-=$decreaseby
    if [[ $octet4 -lt $maxOctetValue && $octet4 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4 | sed 's/-//g'
        return 0
    fi
    echo $octet4
    echo $maxOctetValue
    octet4=$(echo $octet4 | sed 's/-//g')
    numRollOver=$((octet4 / maxOctetValue))
    echo $numRollOver
    let octet4-=$((numRollOver * maxOctetValue))
    echo $((numRollOver - octet3))
    let octet3-=$numRollOver
    echo $octet3
    if [[ $octet3 -lt $maxOctetValue && $octet3 -ge 0 ]]; then
        echo 'here'
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4 | sed 's/-//g'
        return 0
    fi
    numRollOver=$((octet3 / maxOctetValue))
    let octet3-=$((numRollOver * maxOctetValue))
    let octet2-=$numRollOver
    if [[ $octet2 -lt $maxOctetValue && $octet2 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4 | sed 's/-//g'
        return 0
    fi
    numRollOver=$((octet2 / maxOctetValue))
    let octet2-=$((numRollOver * maxOctetValue))
    let octet1-=$numRollOver
    if [[ $octet1 -lt $maxOctetValue && $octet1 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4 | sed 's/-//g'
        return 0
    fi
    return 1
}
addToAddress() {
    local ipaddress="$1"
    local increaseby=$2
    local maxOctetValue=256
    local octet1=""
    local octet2=""
    local octet3=""
    local octet4=""
    oIFS=$IFS
    IFS='.' read octet1 octet2 octet3 octet4 <<< "$ipaddress"
    IFS=$oIFS
    let octet4+=$increaseby
    if [[ $octet4 -lt $maxOctetValue && $octet4 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4
        return 0
    fi
    numRollOver=$((octet4 / maxOctetValue))
    let octet4-=$((numRollOver * maxOctetValue))
    let octet3+=$numRollOver
    if [[ $octet3 -lt $maxOctetValue && $octet3 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4
        return 0
    fi
    numRollOver=$((octet3 / maxOctetValue))
    let octet3-=$((numRollOver * maxOctetValue))
    let octet2+=$numRollOver
    if [[ $octet2 -lt $maxOctetValue && $octet2 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4
        return 0
    fi
    numRollOver=$((octet2 / maxOctetValue))
    let octet2-=$((numRollOver * maxOctetValue))
    let octet1+=$numRollOver
    if [[ $octet1 -lt $maxOctetValue && $octet1 -ge 0 ]]; then
        printf "%d.%d.%d.%d\n" $octet1 $octet2 $octet3 $octet4
        return 0
    fi
    return 1
}
getAllNetworkInterfaces() {
    gatewayif=$(ip -4 route show | grep "^default via" | awk '{print $5}')
    if [[ -z ${gatewayif} ]]; then
        interfaces="$(ip -4 link | grep -v LOOPBACK | grep UP | awk -F': |@' '{print $2}' | tr '\n' ' ')"
    else
        interfaces="$gatewayif $(ip -4 link | grep -v LOOPBACK | grep UP | awk -F': |@' '{print $2}' | tr '\n' ' ' | sed "s/${gatewayif}//g")"
    fi
    echo -n $interfaces
}
checkInternetConnection() {
    dots "Testing internet connection"
    DEBIAN_FRONTEND=noninteractive $packageinstaller curl >>$error_log 2>&1

    http_sites=("neverssl.com" "httpbin.org")
    https_sites=("github.com" "fogproject.org")
    dns_ok=0
    http_ok=0
    https_ok=0

    for dnsname in "${http_sites[@]}" "${https_sites[@]}"; do
        echo -n "Testing DNS name resolution (${dnsname})... " >> $error_log
        getent hosts ${dnsname} >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo "Failed" >> $error_log
            continue
        fi
        dns_ok=1
        echo "OK" >> $error_log
        break
    done
    if [[ $dns_ok -eq 0 ]]; then
        echo "Failed"
        echo
        echo "There seems to be a DNS problem. Check the contents of /etc/resolv.conf" | tee -a $error_log
        echo "If this is CentOS, RHEL, or Fedora or an other RH variant, also check" | tee -a $error_log
        echo "the DNS entries in /etc/sysconfig/network-scripts/ifcfg-*" | tee -a $error_log
        echo
        return
    fi
    for url in "${http_sites[@]}"; do
        echo -n "Testing HTTP connection (http://${url})... " >> $error_log
        curl --silent http://${url} >/dev/null 2>>$error_log
        if [[ $? -ne 0 ]]; then
            echo "Failed" >> $error_log
            continue
        fi
        http_ok=1
        echo "OK" >> $error_log
        break
    done
    for url in "${https_sites[@]}"; do
        echo -n "Testing HTTPS connection (https://${url})... " >> $error_log
        curl --silent -k https://${url} >/dev/null 2>>$error_log
        if [[ $? -ne 0 ]]; then
            echo "Failed" >> $error_log
            continue
        fi
        https_ok=1
        echo "OK" >> $error_log
        break
    done
    if [[ $http_ok -eq 0 && $https_ok -eq 0 ]]; then
        echo "Failed"
        echo
        echo "There was no interface with an active internet connection found." | tee -a $error_log
        echo "If you are using a proxy server, please export http_proxy and https_proxy or use .curlrc" | tee -a $error_log
        echo
        return
    fi
    echo "Done"
}
join() {
    local IFS="$1"
    shift
    echo "$*"
}
restoreReports() {
    dots "Restoring user reports"
    if [[ -d $webdirdest/management/reports ]]; then
        if [[ -d ../rpttmp/ ]]; then
            cp -a ../rpttmp/* $webdirdest/management/reports/
        fi
    fi
    errorStat $?
}
installFOGServices() {
    dots "Setting up FOG Services"
    mkdir -p $servicedst
    cp -Rf $servicesrc/* $servicedst/
    chmod +x -R $servicedst/
    mkdir -p $servicelogs
    errorStat $?
}
configureUDPCast() {
    dots "Setting up UDPCast"
    cur=$(pwd)
    [[ ! -d ../tmp/ ]] && mkdir -p ../tmp/ >/dev/null 2>&1
    cd ../tmp
    rm -rf $udpcastout
    tar xzf $udpcastsrc >>$error_log 2>&1
    cd $udpcastout
    grep -q 'BCM[0-9][0-9][0-9][0-9]' /proc/cpuinfo >>$error_log 2>&1
    if [[ $? -eq 0 ]]; then
        wget -qO config.guess "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess" >>$error_log 2>&1
        wget -qO config.sub "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub" >>$error_log 2>&1
        chmod +x config.guess config.sub >>$error_log 2>&1
    fi
    errorStat $?
    dots "Configuring UDPCast"
    ./configure >>$error_log 2>&1
    errorStat $?
    dots "Building UDPCast"
    make >>$error_log 2>&1
    errorStat $?
    dots "Installing UDPCast"
    make install >>$error_log 2>&1
    errorStat $?
    cd $cur
}
configureFTP() {
    dots "Setting up and starting VSFTP Server"
    if [[ -f $ftpxinetd ]]; then
        mv $ftpxinetd ${ftpxinetd}.fogbackup
    fi
    vsftp=$(vsftpd -version 0>&1 | awk -F'version ' '{print $2}')
    vsvermaj=$(echo $vsftp | awk -F. '{print $1}')
    vsverbug=$(echo $vsftp | awk -F. '{print $3}')
    seccompsand=""
    allow_writeable_chroot=""
    if [[ $vsvermaj -gt 3 ]] || [[ $vsvermaj -eq 3 && $vsverbug -ge 2 ]]; then
        seccompsand="seccomp_sandbox=NO"
    fi
    mv -fv "${ftpconfig}" "${ftpconfig}.${timestamp}" >>$error_log 2>&1
    echo -e  "max_per_ip=200\nanonymous_enable=NO\nlocal_enable=YES\nwrite_enable=YES\nlocal_umask=022\ndirmessage_enable=YES\nxferlog_enable=YES\nconnect_from_port_20=YES\nxferlog_std_format=YES\nlisten=YES\npam_service_name=vsftpd\nuserlist_enable=NO\nchmod_enable=YES\n$seccompsand" > "$ftpconfig"
    diffconfig "${ftpconfig}"
    case $systemctl in
        yes)
            systemctl is-enabled --quiet vsftpd && true || systemctl enable vsftpd >>$error_log 2>&1
            systemctl is-active --quiet vsftpd && systemctl stop vsftpd >>$error_log 2>&1 || true
            systemctl is-active --quiet vsftpd && true || systemctl start vsftpd >>$error_log 2>&1
            systemctl status vsftpd >>$error_log 2>&1
            ;;
        *)
            case $osid in
                2)
                    sysv-rc-conf vsftpd on >>$error_log 2>&1
                    service vsftpd stop >>$error_log 2>&1
                    service vsftpd start >>$error_log 2>&1
                    service vsftpd status >>$error_log 2>&1
                    ;;
                *)
                    chkconfig vsftpd on >>$error_log 2>&1
                    service vsftpd stop >>$error_log 2>&1
                    service vsftpd start >>$error_log 2>&1
                    service vsftpd status >>$error_log 2>&1
                    ;;
            esac
            ;;
    esac
    errorStat $?
}
configureDefaultiPXEfile() {
    dots 'Configuring default iPXE file'
    [[ -z $webroot ]] && webroot='/'
    echo -e "#!ipxe\nset arch \${buildarch}\niseq \${arch} i386 && cpuid --ext 29 && set arch x86_64 ||\nparams\nparam mac0 \${net0/mac}\nparam arch \${arch}\nparam platform \${platform}\nparam product \${product}\nparam manufacturer \${product}\nparam ipxever \${version}\nparam filename \${filename}\nparam sysuuid \${uuid}\nisset \${net1/mac} && param mac1 \${net1/mac} || goto bootme\nisset \${net2/mac} && param mac2 \${net2/mac} || goto bootme\n:bootme\nchain ${httpproto}://$ipaddress${webroot}service/ipxe/boot.php##params" > "$tftpdirdst/default.ipxe"
    errorStat $?
}
configureTFTPandPXE() {
    [[ -d ${tftpdirdst}.prev ]] && rm -rf ${tftpdirdst}.prev >>$error_log 2>&1
    [[ ! -d ${tftpdirdst} ]] && mkdir -p $tftpdirdst >>$error_log 2>&1
    [[ -e ${tftpdirdst}.fogbackup ]] && rm -rf ${tftpdirdst}.fogbackup >>$error_log 2>&1
    [[ -d $tftpdirdst && ! -d ${tftpdirdst}.prev ]] && mkdir -p ${tftpdirdst}.prev >>$error_log 2>&1
    [[ -d ${tftpdirdst}.prev ]] && cp -Rf $tftpdirdst/* ${tftpdirdst}.prev/ >>$error_log 2>&1
    if [[ "x$httpproto" = "xhttps" ]]; then
        dots "Compiling iPXE binaries trusting your SSL certificate"
        cd $buildipxesrc
        ./buildipxe.sh ${sslpath}CA/.fogCA.pem >>$workingdir/error_logs/fog_ipxe-build_${version}.log 2>&1
        errorStat $?
        cd $workingdir
    fi
    cd $tftpdirsrc
    find -type d -exec mkdir -p $tftpdirdst/{} \; >>$error_log 2>&1
    find -type f -exec cp -Rfv {} $tftpdirdst/{} \; >>$error_log 2>&1
    cd $workingdir
    chown -R $username $tftpdirdst >>$error_log 2>&1
    chown -R $username $webdirdest/service/ipxe >>$error_log 2>&1
    find $tftpdirdst -type d -exec chmod 755 {} \; >>$error_log 2>&1
    find $webdirdest -type d -exec chmod 755 {} \; >>$error_log 2>&1
    find $tftpdirdst ! -type d -exec chmod 655 {} \; >>$error_log 2>&1
    configureDefaultiPXEfile
    dots 'Setting up and starting TFTP Server'
    case $systemctl in
        yes)
            # make sure xinetd is off for all systemd distros as we don't use it anymore
            systemctl is-enabled --quiet xinetd 2>/dev/null && systemctl disable xinetd >>$error_log 2>&1 || true
            systemctl is-active --quiet xinetd && systemctl stop xinetd >>$error_log 2>&1 || true
            if [[ -f /etc/xinetd.d/tftp ]]; then
                rm -f /etc/xinetd.d/tftp
            fi
            if [[ $osid -eq 2 && -f $tftpconfigupstartdefaults ]]; then
                echo -e "# /etc/default/tftpd-hpa\n# FOG Modified version\nTFTP_USERNAME=\"root\"\nTFTP_DIRECTORY=\"/tftpboot\"\nTFTP_ADDRESS=\":69\"\nTFTP_OPTIONS=\"${tftpAdvOpts:+$tftpAdvOpts }-s\"" > "$tftpconfigupstartdefaults"
                systemctl is-enabled --quiet tftpd-hpa && true || systemctl enable tftpd-hpa >>$error_log 2>&1
                systemctl is-active --quiet tftpd-hpa && systemctl stop tftpd-hpa >>$error_log 2>&1 || true
                systemctl is-active --quiet tftpd-hpa && true || systemctl start tftpd-hpa >>$error_log 2>&1
                systemctl status tftpd-hpa >>$error_log 2>&1
            else
                if [[ -f /etc/systemd/system/fog-tftp.service ]]; then
                    mv -fv /etc/systemd/system/fog-tftp.service "/etc/systemd/system/fog-tftp.service.${timestamp}" >>$error_log 2>&1
                fi
                echo -e "[Unit]\nDescription=Tftp Server\nRequires=fog-tftp.socket\nDocumentation=man:in.tftpd\n\n[Service]\nExecStart=/usr/sbin/in.tftpd ${tftpAdvOpts:+$tftpAdvOpts }-s ${tftpdirdst}\nStandardInput=socket\n\n[Install]\nAlso=fog-tftp.socket" > /etc/systemd/system/fog-tftp.service
                diffconfig "/etc/systemd/system/fog-tftp.service"
                cp -v /usr/lib/systemd/system/tftp.socket /etc/systemd/system/fog-tftp.socket >>$error_log 2>&1
                systemctl daemon-reload
                systemctl is-enabled --quiet fog-tftp.socket && true || systemctl enable fog-tftp.socket >>$error_log 2>&1
                systemctl is-active --quiet fog-tftp.socket && systemctl stop fog-tftp.socket >>$error_log 2>&1 || true
                systemctl is-active --quiet fog-tftp.socket && true || systemctl start fog-tftp.socket >>$error_log 2>&1
                systemctl status fog-tftp.socket >>$error_log 2>&1
            fi
            ;;
        *)
            if [[ $osid -eq 2 && -f $tftpconfigupstartdefaults ]]; then
                echo -e "# /etc/default/tftpd-hpa\n# FOG Modified version\nTFTP_USERNAME=\"root\"\nTFTP_DIRECTORY=\"/tftpboot\"\nTFTP_ADDRESS=\":69\"\nTFTP_OPTIONS=\"${tftpAdvOpts:+$tftpAdvOpts }-s\"" > "$tftpconfigupstartdefaults"
                sysv-rc-conf xinetd off >>$error_log 2>&1
                service xinetd stop >>$error_log 2>&1
                sysv-rc-conf tftpd-hpa on >>$error_log 2>&1
                service tftpd-hpa stop >>$error_log 2>&1
                service tftpd-hpa start >>$error_log 2>&1
            elif [[ $osid -eq 2 ]]; then
                sysv-rc-conf xinetd on >>$error_log 2>&1
                $initdpath/xinetd stop >>$error_log 2>&1
                $initdpath/xinetd start >>$error_log 2>&1
            else
                chkconfig xinetd on >>$error_log 2>&1
                service xinetd stop >>$error_log 2>&1
                service xinetd start >>$error_log 2>&1
                service xinetd status >>$error_log 2>&1
            fi
            ;;
    esac
    errorStat $?
}
configureMinHttpd() {
    configureHttpd
    echo "<?php" > "$webdirdest/management/index.php"
    echo "/**" >> "$webdirdest/management/index.php"
    echo " * The main index presenter" >> "$webdirdest/management/index.php"
    echo " *" >> "$webdirdest/management/index.php"
    echo " * PHP version 5" >> "$webdirdest/management/index.php"
    echo " *" >> "$webdirdest/management/index.php"
    echo " * @category Index_Page" >> "$webdirdest/management/index.php"
    echo " * @package  FOGProject" >> "$webdirdest/management/index.php"
    echo " * @author   Tom Elliott <tommygunsster@gmail.com>" >> "$webdirdest/management/index.php"
    echo " * @license  http://opensource.org/licenses/gpl-3.0 GPLv3" >> "$webdirdest/management/index.php"
    echo " * @link     https://fogproject.org" >> "$webdirdest/management/index.php"
    echo " */" >> "$webdirdest/management/index.php"
    echo "/**" >> "$webdirdest/management/index.php"
    echo " * The main index presenter" >> "$webdirdest/management/index.php"
    echo " *" >> "$webdirdest/management/index.php"
    echo " * @category Index_Page" >> "$webdirdest/management/index.php"
    echo " * @package  FOGProject" >> "$webdirdest/management/index.php"
    echo " * @author   Tom Elliott <tommygunsster@gmail.com>" >> "$webdirdest/management/index.php"
    echo " * @license  http://opensource.org/licenses/gpl-3.0 GPLv3" >> "$webdirdest/management/index.php"
    echo " * @link     https://fogproject.org" >> "$webdirdest/management/index.php"
    echo " */" >> "$webdirdest/management/index.php"
    echo "require '../commons/base.inc.php';" >> "$webdirdest/management/index.php"
    echo "require '../commons/text.php';" >> "$webdirdest/management/index.php"
    echo "ob_start();" >> "$webdirdest/management/index.php"
    echo "FOGCore::getClass('FOGPageManager')->render();" >> "$webdirdest/management/index.php"
    echo "ob_end_clean();" >> "$webdirdest/management/index.php"
    echo "die(_('This is a storage node, please do not access the web ui here!'));" >> "$webdirdest/management/index.php"
}
addOndrejRepo() {
    find /etc/apt/sources.list.d/ -name '*ondrej*' -exec rm -rf {} \; >>$error_log 2>&1
    DEBIAN_FRONTEND=noninteractive $packageinstaller python-software-properties >>$error_log 2>&1
    DEBIAN_FRONTEND=noninteractive $packageinstaller software-properties-common >>$error_log 2>&1
    DEBIAN_FRONTEND=noninteractive $packageinstaller ntpdate >>$error_log 2>&1
    ntpdate pool.ntp.org >>$error_log 2>&1
    locale-gen 'en_US.UTF-8' >>$error_log 2>&1
    LANG='en_US.UTF-8' LC_ALL='en_US.UTF-8' add-apt-repository -y ppa:ondrej/php >>$error_log 2>&1
    LANG='en_US.UTF-8' LC_ALL='en_US.UTF-8' add-apt-repository -y ppa:ondrej/apache2 >>$error_log 2>&1
}
installPackages() {
    [[ $installlang -eq 1 ]] && packages="$packages gettext"
    packages="$packages unzip"
    dots "Adjusting repository (can take a long time for cleanup)"
    case $osid in
        1)
            packages="$packages php-bcmath bc"
            if [[ $installlang -eq 1 ]]; then
                packages="$packages php-intl"
                for i in fr de eu es pt zh en; do
                    packages="$packages glibc-langpack-${i}";
                done
            fi
            packages="${packages// mod_fastcgi/}"
            packages="${packages// mod_evasive/}"
            packages="${packages// php-mcrypt/}"
            case $linuxReleaseName_lower in
                *fedora*)
                    packages="$packages php-json"
                    packages="${packages// mysql / mariadb }" >>$error_log 2>&1
                    packages="${packages// mysql-server / mariadb-server }" >>$error_log 2>&1
                    packages="${packages// dhcp / dhcp-server }" >>$error_log 2>&1
                    ;;
                *)
                    x="epel-release"
                    eval $packageQuery >>$error_log 2>&1
                    if [[ ! $? -eq 0 ]]; then
                        y="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OSVersion}.noarch.rpm"
                        $packageinstaller $y >>$error_log 2>&1
                        errorStat $? "skipOk"
                    fi
                    y="https://rpms.remirepo.net/enterprise/remi-release-${OSVersion}.rpm"
                    x="$(basename $y | awk -F[.] '{print $1}')*"
                    eval $packageQuery >>$error_log 2>&1
                    if [[ ! $? -eq 0 ]]; then
                        rpm -Uvh $y >>$error_log 2>&1
                        errorStat $? "skipOk"
                    fi
                    rpm --import "https://rpms.remirepo.net/RPM-GPG-KEY-remi" >>$error_log 2>&1
                    errorStat $? "skipOk"
                    if [[ -n $repoenable ]]; then
                        if [[ $OSVersion -le 7 ]]; then
                            $repoenable epel >>$error_log 2>&1 || true
                            $repoenable remi >>$error_log 2>&1 || true
                            $repoenable remi-php72 >>$error_log 2>&1 || true
                        fi
                    fi
                    ;;
            esac
            ;;
        2)
            packages="${packages// libapache2-mod-fastcgi/}"
            packages="${packages// libapache2-mod-evasive/}"
            packages="${packages// xinetd/}"
            packages="${packages// php-gettext/}"
            packages="${packages// php-php-gettext/}"
            packages="${packages} php-bcmath bc"
            if [[ $installlang -eq 1 ]]; then
                packages="$packages php-intl"
            fi
            case $linuxReleaseName_lower in
                *ubuntu*|*mint*)
                    if [[ $installlang -eq 1 ]]; then
                        for i in fr de eu es pt zh-hans en; do
                            packages="$packages language-pack-${i}";
                        done
                    fi
                    if [[ $OSVersion -gt 17 ]]; then
                        packages="${packages// libcurl3 / libcurl4 }">>$error_log 2>&1
                    fi
                    if [[ $OSVersion -ge 22 ]]; then
                        packages="${packages// libcurl4 / libcurl4t64 }">>$error_log 2>&1
                    fi
                    if [[ $linuxReleaseName_lower == +(*ubuntu*) && $OSVersion -ge 18 ]]; then
                        # Fix missing universe section for Ubuntu 18.04 LIVE
                        LANG='en_US.UTF-8' LC_ALL='en_US.UTF-8' add-apt-repository -y universe >>$error_log 2>&1
                        # check to see if we still have packages from deb.sury.org (a.k.a ondrej) installed and try to clean it up
                        dpkg -l | grep -q "deb\.sury\.org"
                        if [[ $? -eq 0 ]]; then
                            # make sure we have ondrej repos enabled to be able to use ppa-purge
                            addOndrejRepo
                            # use ppa-purge to not just remove the repo but also downgrade packages to Ubuntu original versions
                            DEBIAN_FRONTEND=noninteractive apt-get install -yq ppa-purge >>$error_log 2>&1
                            ppa-purge -y ppa:ondrej/apache2 >>$error_log 2>&1
                            # for php we want to purge all packages first as we don't want ppa-purge to try downgrading those
                            DEBIAN_FRONTEND=noninteractive apt-get purge -yq 'php5*' 'php7*' 'php8*' 'libapache*' >>$error_log 2>&1
                            ppa-purge -y ppa:ondrej/php >>$error_log 2>&1
                            DEBIAN_FRONTEND=noninteractive apt-get purge -yq ppa-purge >>$error_log 2>&1
                        fi
                    else
                        addOndrejRepo
                    fi
                    ;;
                *bian*)
                    if [[ $OSVersion -ge 10 ]]; then
                        packages="${packages// libcurl3 / libcurl4 }">>$error_log 2>&1
                        packages="${packages// mysql-client / mariadb-client }">>$error_log 2>&1
                        packages="${packages// mysql-server / mariadb-server }">>$error_log 2>&1
                    fi
                    ;;
            esac
            ;;
        3)
            echo $packages | grep -q -v " git" && packages="${packages} git"
            packages="${packages// php-mcrypt/}"
            ;;
    esac
    errorStat $?
    dots "Preparing Package Manager"
    $packmanUpdate >>$error_log 2>&1
    if [[ $osid -eq 2 ]]; then
        if [[ $? != 0 ]] && [[ $linuxReleaseName_lower == +(*ubuntu*|*mint*) ]]; then
            cp /etc/apt/sources.list /etc/apt/sources.list.original_fog_$(date +%s)
            sed -i -e 's/\/\/*archive.ubuntu.com\|\/\/*security.ubuntu.com/\/\/old-releases.ubuntu.com/g' /etc/apt/sources.list
            $packmanUpdate >>$error_log 2>&1
            if [[ $? != 0 ]]; then
                cp -f /etc/apt/sources.list.original_fog /etc/apt/sources.list >>$error_log 2>&1
                rm -f /etc/apt/sources.list.original_fog >>$error_log 2>&1
                false
            fi
        fi
    fi
    errorStat $?
    packages=$(echo ${packages[@]} | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo -e " * Packages to be installed:\n\n\t$packages\n\n"
    newPackList=""
    local toInstall=""
    for x in $packages; do
        case $x in
            mysql|mariadb|mariadb-client|MariaDB-client)
                for sqlclient in $sqlclientlist; do
                    eval $packagelist "$sqlclient" >>$error_log 2>&1
                    if [[ $? -eq 0 ]]; then
                        available_sqlclient=$sqlclient
                        break
                    fi
                done
                for sqlclient in $sqlclientlist; do
                    x=$sqlclient
                    eval $packageQuery >>$error_log 2>&1
                    if [[ $? -eq 0 ]]; then
                        installed_sqlclient=$sqlclient
                        break
                    fi
                done
                [[ -z $installed_sqlclient ]] && x=$available_sqlclient || x=$installed_sqlclient
                ;;
            mysql-server|mariadb-server|MariaDB-server)
                for sqlserver in $sqlserverlist; do
                    eval $packagelist "$sqlserver" >>$error_log 2>&1
                    if [[ $? -eq 0 ]]; then
                        available_sqlserver=$sqlserver
                        break
                    fi
                done
                for sqlserver in $sqlserverlist; do
                    x=$sqlserver
                    eval $packageQuery >>$error_log 2>&1
                    if [[ $? -eq 0 ]]; then
                        installed_sqlserver=$sqlserver
                        break
                    fi
                done
                [[ -z $installed_sqlserver ]] && x=$available_sqlserver || x=$installed_sqlserver
                ;;
            php-json)
                for json in php-json php-common; do
                    eval $packagelist "$json" >>$error_log 2>&1
                    if [[ $? -eq 0 ]]; then
                        x=$json
                        break
                    fi
                done
                ;;
            php-mysql*)
                for phpmysql in $(echo php-mysqlnd php-mysql); do
                    eval $packagelist "$phpmysql" >>$error_log 2>&1
                    if [[ $? -eq 0 ]]; then
                        x=$phpmysql
                        break
                    fi
                done
                ;;
        esac
        [[ $osid == 2 && -z $dhcpd && $x == +(*'dhcp'*) ]] && dhcpd=$x
        eval $packageQuery >>$error_log 2>&1
        if [[ $? -eq 0 ]]; then
            dots "Skipping package:   $x"
            echo "(Already Installed)"
            newPackList="$newPackList $x"
            continue
        fi
        eval $packagelist "$x" >>$error_log 2>&1
        if [[ ! $? -eq 0 ]]; then
            dots "Skipping package: $x"
            echo "(Does not exist)"
            continue
        fi
        newPackList="$newPackList $x"
        dots "Installing package: $x"
        DEBIAN_FRONTEND=noninteractive $packageinstaller $x >>$error_log 2>&1
        if [[ ! $? -eq 0 ]]; then
            echo "Failed! (Will try later)"
            [[ -z $toInstall ]] && toInstall="$x" || toInstall="$toInstall $x"
        else
            echo "OK"
        fi
    done
    packages=$newPackList
    packages=$(echo ${packages[@]} | tr ' ' '\n' | sort -u | tr '\n' ' ')
    dots "Updating packages as needed"
    DEBIAN_FRONTEND=noninteractive $packageupdater $packages >>$error_log 2>&1
    echo "OK"
    if [[ -n $toInstall ]]; then
        toInstall=$(echo ${toInstall[@]} | tr ' ' '\n' | sort -u | tr '\n' ' ')
        dots "Installing now everything is updated"
        DEBIAN_FRONTEND=noninteractive $packageinstaller $toInstall >>$error_log 2>&1
        errorStat $?
    fi
    export php_ver=$(php -i | grep "PHP Version" | head -1 | cut -d' ' -f 4 | cut -d'.' -f1-2)
    [[ -z ${phpfpm} ]] && export phpfpm="php${php_ver}-fpm"
    [[ -z ${phpini} ]] && export phpini="/etc/php/$php_ver/fpm/php.ini"
}
confirmPackageInstallation() {
    for x in $packages; do
        dots "Checking package: $x"
        eval $packageQuery >>$error_log 2>&1
        errorStat $?
    done
}
checkSELinux() {
    command -v sestatus >>$error_log 2>&1
    exitcode=$?
    [[ $exitcode -ne 0 ]] && return
    currentmode=$(LANG=C sestatus | grep "^Current mode" | awk '{print $3}')
    configmode=$(LANG=C sestatus | grep "^Mode from config file" | awk '{print $5}')
    [[ "x$currentmode" != "xenforcing" && "x$configmode" != "xenforcing" ]] && return
    echo " * SELinux is currently enabled on your system. This is often causing"
    echo " * issues and we recommend setting to permissive on FOG Servers as of now."
    echo -n " * Should the installer set this for you now? (Y/n) "
    sedisable=""
    while [[ -z $sedisable ]]; do
        [[ -n $autoaccept ]] && sedisable="Y" || read -r sedisable
        case $sedisable in
            [Yy]|[Yy][Ee][Ss]|"")
                sedisable="Y"
                setenforce 0
                sed -i 's/^SELINUX=.*$/SELINUX=permissive/' /etc/selinux/config
                echo -e " * SELinux set permissive -- proceeding with installation...\n"
                ;;
            [Nn]|[Nn][Oo])
                echo -e " * You sure know what you're doing, just keep in mind we told you! :-)\n"
                ;;
            *)
                sedisable=""
                echo " * Invalid input, please try again!"
                ;;
        esac
    done
}
checkFirewall() {
    command -v iptables >>$error_log
    iptcmd=$?
    if [[ $iptcmd -eq 0 ]]; then
        rulesnum=$(iptables -L -n | wc -l)
        policy=$(iptables -L -n | grep "^Chain" | grep -v "ACCEPT" -c)
        [[ $rulesnum -ne 8 || $policy -ne 0 ]] && fwrunning=1
    fi
    command -v firewall-cmd >>$error_log 2>&1
    fwcmd=$?
    if [[ $fwcmd -eq 0 ]]; then
        fwstate=$(firewall-cmd --state 2>&1)
        [[ "x$fwstate" == "xrunning" ]] && fwrunning=1
    fi
    [[ $fwrunning -ne 1 ]] && return
    echo " * The local firewall, currently, seems to be enabled on your system. This can cause"
    echo " * issues on FOG Servers if you are not well experienced and know what you are doing."
    echo -n " * Should the installer try to disable the local firewall for you now? (y/N) "
    fwdisable=""
    while [[ -z $fwdisable ]]; do
        [[ -n $autoaccept ]] && fwdisable="N" || read -r fwdisable
        case $fwdisable in
            [Yy]|[Yy][Ee][Ss])
                ufw stop >/dev/null 2>&1
                ufw disable >/dev/null 2>&1
                systemctl is-active --quiet ufw && systemctl stop ufw >/dev/null 2>&1 || true
                systemctl is-enabled --quiet ufw 2>/dev/null && systemctl disable ufw >/dev/null 2>&1 || true
                systemctl is-active --quiet firewalld && systemctl stop firewalld >/dev/null 2>&1 || true
                systemctl is-enabled --quiet firewalld 2>/dev/null && systemctl disable firewalld >/dev/null 2>&1 || true
                systemctl is-active --quiet iptables && systemctl stop iptables >/dev/null 2>&1 || true
                systemctl is-enabled --quiet iptables 2>/dev/null && systemctl disable iptables >/dev/null 2>&1 || true
                local cannotdisablefw=0
                if [[ $iptcmd -eq 0 ]]; then
                    rulesnum=$(iptables -L -n | wc -l)
                    policy=$(iptables -L -n | grep "^Chain" | grep -v "ACCEPT" -c)
                    [[ $rulesnum -ne 8 || $policy -ne 0 ]] && cannotdisablefw=1
                fi
                if [[ $fwcmd -eq 0 ]]; then
                    fwstate=$(firewall-cmd --state 2>&1)
                    [[ "x$fwstate" == "xrunning" ]] && cannotdisablefw=1
                fi
                if [[ $cannotdisablefw -eq 0 ]]; then
                    echo -e " * Firewall disabled - proceeding with installation...\n"
                else
                    echo " * We were unable to disable the firewall on your system. Read up on how"
                    echo " * you can disable it manually. Proceeding with the installation anyway..."
                    echo " * Hit [Enter] so we know you've read this message."
                    read
                fi
                ;;
            [Nn]|[Nn][Oo]|"")
                fwdisable="N"
                echo " * You sure know what you are doing, just keep in mind we told you! :-)"
                if [[ -z $autoaccept ]]; then
                    echo " * Hit ENTER so we know you've read this message."
                    read
                fi
                ;;
            *)
                fwdisable=""
                echo " * Invalid input, please try again!"
                ;;
        esac
    done
}
displayOSChoices() {
    blFirst=1
    while [[ -z $osid ]]; do
        if [[ $fogupdateloaded -eq 1 && $blFirst -eq 1 ]]; then
            blFirst=0
        else
            osid=$strSuggestedOS
            if [[ -z $autoaccept && ! -z $osid ]]; then
                echo "  What version of Linux would you like to run the installation for?"
                echo
                echo "          1) Redhat Based Linux (Redhat, Alma, Rocky, CentOS, Mageia)"
                echo "          2) Debian Based Linux (Debian, Ubuntu, Kubuntu, Edubuntu)"
                echo "          3) Arch Linux"
                echo
                echo -n "  Choice: [$strSuggestedOS] "
                read osid
                case $osid in
                    "")
                        osid=$strSuggestedOS
                        break
                        ;;
                    1|2|3)
                        break
                        ;;
                    *)
                        echo "  Invalid input, please try again."
                        osid=""
                        ;;
                esac
            fi
        fi
    done
    doOSSpecificIncludes
}
doOSSpecificIncludes() {
    echo
    case $osid in
        1)
            echo -e "\n\n  Starting Redhat based Installation\n\n"
            osname="Redhat"
            . ../lib/redhat/config.sh
            ;;
        2)
            echo -e "\n\n  Starting Debian based Installation\n\n"
            osname="Debian"
            . ../lib/ubuntu/config.sh
            ;;
        3)
            echo -e "\n\n  Starting Arch Installation\n\n"
            osname="Arch"
            . ../lib/arch/config.sh
            systemctl="yes"
            ;;
        *)
            echo -e "  Sorry, answer not recognized\n\n"
            sleep 2
            osid=""
            ;;
    esac
    currentdir=$(pwd)
    case $currentdir in
        *$webdirdest*|*$tftpdirdst*)
            echo "Please change installation directory."
            echo "Running from here will fail."
            echo "You are in $currentdir which is a folder that will"
            echo "be moved during installation."
            exit 1
            ;;
    esac
}
errorStat() {
    local status=$1
    local skipOk=$2
    if [[ $status != 0 ]]; then
        echo "Failed!"
        if [[ -z $exitFail ]]; then
            echo
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "!! The installer was not able to run all the way to the end as   !!"
            echo "!! something has caused it to fail. The following few lines are  !!"
            echo "!! from the error log file which might help us figure out what's !!"
            echo "!! wrong. Please add this information when reporting an error.   !!"
            echo "!! As well you might want to take a look at the full error log   !!"
            echo "!! in $error_log !!"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo
            tail -n 5 $error_log
            exit $status
        fi
    fi
    [[ -z $skipOk ]] && echo "OK"
}
stopInitScript() {
    for serviceItem in $serviceList; do
        dots "Stopping $serviceItem Service"
        if [ "$systemctl" == "yes" ]; then
            systemctl is-active --quiet $serviceItem && systemctl stop $serviceItem >>$error_log 2>&1 || true
        else
            [[ ! -x $initdpath/$serviceItem ]] && continue
            $initdpath/$serviceItem status >/dev/null 2>&1 && $initdpath/$serviceItem stop >>$error_log 2>&1
        fi
        echo "OK"
    done
}
startInitScript() {
    for serviceItem in $serviceList; do
        dots "Starting $serviceItem Service"
        if [[ $systemctl == yes ]]; then
            systemctl is-active --quiet $serviceItem && true || systemctl start $serviceItem >>$error_log 2>&1
        else
            [[ ! -x $initdpath/$serviceItem ]] && continue
            $initdpath/$serviceItem status >/dev/null 2>&1 || $initdpath/$serviceItem start >>$error_log 2>&1
        fi
        errorStat $?
    done
}
enableInitScript() {
    for serviceItem in $serviceList; do
        case $systemctl in
            yes)
                dots "Setting permissions on $serviceItem script"
                chmod 644 $initdpath/$serviceItem >>$error_log 2>&1
                errorStat $?
                dots "Enabling $serviceItem Service"
                systemctl is-enabled --quiet $serviceItem && true || systemctl enable $serviceItem >>$error_log 2>&1
                if [[ ! $? -eq 0 && $osid -eq 2 ]]; then
                    update-rc.d $(echo $serviceItem | sed -e 's/[.]service//g') enable 2 >>$error_log 2>&1
                    update-rc.d $(echo $serviceItem | sed -e 's/[.]service//g') enable 3 >>$error_log 2>&1
                    update-rc.d $(echo $serviceItem | sed -e 's/[.]service//g') enable 4 >>$error_log 2>&1
                    update-rc.d $(echo $serviceItem | sed -e 's/[.]service//g') enable 5 >>$error_log 2>&1
                fi
                ;;
            *)
                dots "Setting $serviceItem script executable"
                chmod +x $initdpath/$serviceItem >>$error_log 2>&1
                errorStat $?
                case $osid in
                    1)
                        dots "Enabling $serviceItem Service"
                        chkconfig $serviceItem on >>$error_log 2>&1
                        ;;
                    2)
                        dots "Enabling $serviceItem Service"
                        sysv-rc-conf $serviceItem off >>$error_log 2>&1
                        sysv-rc-conf $serviceItem on >>$error_log 2>&1
                        case $linuxReleaseName_lower in
                            *ubuntu*|*mint*)
                                /usr/lib/insserv/insserv -r $initdpath/$serviceItem >>$error_log 2>&1
                                /usr/lib/insserv/insserv -d $initdpath/$serviceItem >>$error_log 2>&1
                                ;;
                            *)
                                insserv -r $initdpath/$serviceItem >>$error_log 2>&1
                                insserv -d $initdpath/$serviceItem >>$error_log 2>&1
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac
        errorStat $?
    done
}
installInitScript() {
    dots "Installing FOG System Scripts"
    cp -f $initdsrc/* $initdpath/ && systemctl daemon-reload >>$error_log 2>&1
    errorStat $?
    echo
    echo
    echo " * Configuring FOG System Services"
    echo
    echo
    enableInitScript
}
configureMySql() {
    stopInitScript
    dots "Setting up and starting MySQL"
    dbservice=$(systemctl list-units | grep -o -e "mariadb\.service" -e "mysqld\.service" -e "mysql\.service" | tr -d '@')
    [[ -z $dbservice ]] && dbservice=$(systemctl list-unit-files | grep -v bad | grep -o -e "mariadb\.service" -e "mysqld\.service" -e "mysql\.service" | tr -d '@')
    for mysqlconf in $(grep -rl '.*skip-networking' /etc | grep -v init.d); do
        sed -i '/.*skip-networking/ s/^#*/#/' -i $mysqlconf >>$error_log 2>&1
    done
    for mysqlconf in `grep -rl '.*bind-address.*=.*127.0.0.1' /etc | grep -v init.d`; do
        sed -e '/.*bind-address.*=.*127.0.0.1/ s/^#*/#/' -i $mysqlconf >>$error_log 2>&1
    done
    if [[ $systemctl == yes ]]; then
        if [[ $osid -eq 3 && ! -f /var/lib/mysql/ibdata1 ]]; then
            mkdir -p /var/lib/mysql >>$error_log 2>&1
            chown -R mysql:mysql /var/lib/mysql >>$error_log 2>&1
            mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >>$error_log 2>&1
        fi
        systemctl is-enabled --quiet $dbservice || systemctl enable $dbservice >>$error_log 2>&1
        systemctl is-active --quiet $dbservice && systemctl stop $dbservice >>$error_log 2>&1
        systemctl start $dbservice >>$error_log 2>&1
    else
        case $osid in
            1)
                chkconfig mysqld on >>$error_log 2>&1
                service mysqld start >>$error_log 2>&1
                ;;
            2)
                sysv-rc-conf mysql on >>$error_log 2>&1
                service mysql start >>$error_log 2>&1
                ;;
        esac
    fi
    # if someone still has DB user root set in .fogsettings we want to change that
    [[ "x$snmysqluser" == "xroot" ]] && snmysqluser='fogmaster'
    [[ -z $snmysqlpass ]] && snmysqlpass=$(generatePassword 20)
    [[ -n $snmysqlhost ]] && host="--host=$snmysqlhost"
    sqloptionsroot="${host} --user=root"
    sqloptionsuser="${host} -s --user=${snmysqluser}"
    mysqladmin $host ping >/dev/null 2>&1 || mysqladmin $host ping >/dev/null 2>&1 || mysqladmin $host ping >/dev/null 2>&1
    errorStat $?

    dots "Setting up MySQL user and database"
    mysql $sqloptionsroot --execute="quit" >/dev/null 2>&1
    connect_as_root=$?
    if [[ $connect_as_root -eq 0 ]]; then
        # Try to detect if we can login to the database as root without a password
        # as there are many legacy installs with empty root password and we want to
        # make things more secure. Since MariaDB 10.1 the authentication plugin
        # called unix_socket is used by default for the DB root account and we want
        # to check if that is the case here first. In case it is a root login with
        # empty or without password is also possible but unix_socket makes it way
        # more secure and if it's set to unix_socket we don't mess with it!
        # MariaDB 10.4 introduced a new table called mysql.global_priv to keep the
        # login information. While mysql.user still exists mysql.global_priv is now
        # in charge. So we need to check that first.
        mysqlrootauth=$(mysql $sqloptionsroot --database=mysql --execute="SELECT * FROM global_priv WHERE Host='localhost' AND User='root' AND Priv LIKE '%unix_socket%'" 2>/dev/null)
        [[ -z $mysqlrootauth ]] && mysqlrootauth=$(mysql $sqloptionsroot --database=mysql --execute="SELECT Host,User,plugin FROM user WHERE Host='localhost' AND User='root' AND plugin='unix_socket'" 2>/dev/null)
        if [[ -z $mysqlrootauth && -z $autoaccept ]]; then
            echo
            echo "   The installer detected a blank database *root* password. This"
            echo "   is very common on a new install or if you upgrade from any"
            echo "   version of FOG before 1.5.8. To improve overall security we ask"
            echo "   you to supply an appropriate database *root* password now."
            echo
            echo "   NOTICE: Make sure you choose a good password but also one"
            echo "   you can remember or use a password manager to store it."
            echo "   The installer won't store the given password in any place"
            echo "   and it will be lost right after the installer finishes!"
            echo
            echo -n "   Please enter a new database *root* password to be set: "
            read -rs snmysqlrootpass
            echo
            echo
            if [[ -z $snmysqlrootpass ]]; then
                snmysqlrootpass=$(generatePassword 20)
                echo
                echo "   We don't accept a blank database *root* password anymore and"
                echo "   will generate a password for you to use. Please make sure"
                echo "   you save the following password in an appropriate place as"
                echo "   the installer won't store it for you."
                echo
                echo "   Database root password: $snmysqlrootpass"
                echo
                echo "   Press [Enter] to procede..."
                read -rs procede
                echo
                echo
            fi
            # WARN: Since MariaDB 10.3 (maybe earlier) setting a password when auth plugin is
            # set to unix_socket will actually switch to auth plugin mysql_native_password
            # automatically which was not the case in MariaDB 10.1 and is causing trouble.
            # So instead of SET PASSWORD we now use mysqladmin as it does not alter the
            # MariaDB auth plugin used.
            mysqladmin $sqloptionsroot password "${snmysqlrootpass}" >>$error_log 2>&1
        fi
        snmysqlstoragepass=$(mysql -s $sqloptionsroot --password="${snmysqlrootpass}" --execute="SELECT settingValue FROM globalSettings WHERE settingKey LIKE '%FOG_STORAGENODE_MYSQLPASS%'" $mysqldbname 2>/dev/null | tail -1)
    else
        snmysqlstoragepass=$(mysql $sqloptionsuser --password="${snmysqlpass}" --execute="SELECT settingValue FROM globalSettings WHERE settingKey LIKE '%FOG_STORAGENODE_MYSQLPASS%'" $mysqldbname 2>/dev/null | tail -1)
    fi
    mysql $sqloptionsuser --password="${snmysqlpass}" --execute="quit" >/dev/null 2>&1
    connect_as_fogmaster=$?
    mysql ${host} -s --user=fogstorage --password="${snmysqlstoragepass}" --execute="quit" >/dev/null 2>&1
    connect_as_fogstorage=$?
    if [[ $connect_as_fogmaster -eq 0 && $connect_as_fogstorage -eq 0 ]]; then
        echo "Skipped"
        return
    fi

    # If we reach this point it's clear that this install is not setup with
    # unpriviledged DB users yet and we need to have root DB access now.
    if [[ $connect_as_root -ne 0 ]]; then
        echo
        echo "   To improve the overall security the installer will create an"
        echo "   unpriviledged database user account for FOG's database access."
        echo "   Please provide the database *root* user password. Be asured"
        echo "   that this password will only be used while the FOG installer"
        echo -n "   is running and won't be stored anywhere: "
        read -rs snmysqlrootpass
        echo
        echo
        mysql $sqloptionsroot --password="${snmysqlrootpass}" --execute="quit" >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo "   Unable to connect to the database using the given password!"
            echo -n "   Try again: "
            read -rs snmysqlrootpass
            mysql $sqloptionsroot --password="${snmysqlrootpass}" --execute="quit" >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                echo
                echo "   Failed! Terminating installer now."
                exit 1
            fi
        fi
    fi

    snmysqlstoragepass=$(mysql -s $sqloptionsroot --password="${snmysqlrootpass}" --execute="SELECT settingValue FROM globalSettings WHERE settingKey LIKE '%FOG_STORAGENODE_MYSQLPASS%'" $mysqldbname 2>/dev/null | tail -1)
    # generate a new fogstorage password if it doesn't exist yet or if it's old style fs0123456789
    if [[ -z $snmysqlstoragepass ]]; then
        snmysqlstoragepass=$(generatePassword 20)
    elif [[ -n $(echo $snmysqlstoragepass | grep "^fs[0-9][0-9]*$") ]]; then
        snmysqlstoragepass=$(generatePassword 20)
        echo
        echo "   The current *fogstorage* database password does not meet high"
        echo "   security standards. We will generate a new password and update"
        echo "   all the settings on this FOG server for you. Please take note"
        echo "   of the following credentials that you need to manually update"
        echo "   on all your storage nodes' /opt/fog/.fogsettings configuration"
        echo "   files and re-run (!) the FOG installer:"
        echo "   snmysqluser='fogstorage'"
        echo "   snmysqlpass='${snmysqlstoragepass}'"
        echo
        if [[ -z $autoaccept ]]; then
            echo "   Press [Enter] to proceed after you noted down the credentials."
            read
        fi
    fi
    [[ ! -d ../tmp/ ]] && mkdir -p ../tmp/ >/dev/null 2>&1
    cat >../tmp/fog-db-and-user-setup.sql <<EOF
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='ANSI' ;
DELETE FROM mysql.user WHERE User='' ;
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1') ;
DROP DATABASE IF EXISTS test ;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%' ;
CREATE DATABASE IF NOT EXISTS $mysqldbname ;
USE $mysqldbname ;
DROP PROCEDURE IF EXISTS $mysqldbname.create_user_if_not_exists ;
DELIMITER $$
CREATE PROCEDURE $mysqldbname.create_user_if_not_exists()
BEGIN
  DECLARE masteruser BIGINT DEFAULT 0 ;
  DECLARE storageuser BIGINT DEFAULT 0 ;

  SELECT COUNT(*) INTO masteruser FROM mysql.user
    WHERE User = '${snmysqluser}' and  Host = '${snmysqlhost}' ;
  IF masteruser > 0 THEN
    DROP USER '${snmysqluser}'@'${snmysqlhost}';
  END IF ;
  CREATE USER '${snmysqluser}'@'${snmysqlhost}' IDENTIFIED BY '${snmysqlpass}' ;
  GRANT ALL PRIVILEGES ON $mysqldbname.* TO '${snmysqluser}'@'${snmysqlhost}' ;

  SELECT COUNT(*) INTO storageuser FROM mysql.user
    WHERE User = 'fogstorage' and  Host = '%' ;
  IF storageuser > 0 THEN
    DROP USER 'fogstorage'@'%';
  END IF ;
  CREATE USER 'fogstorage'@'%' IDENTIFIED BY '${snmysqlstoragepass}' ;
END ;$$
DELIMITER ;
CALL $mysqldbname.create_user_if_not_exists() ;
DROP PROCEDURE IF EXISTS $mysqldbname.create_user_if_not_exists ;
FLUSH PRIVILEGES ;
SET SQL_MODE=@OLD_SQL_MODE ;
EOF
    mysql $sqloptionsroot --password="${snmysqlrootpass}" <../tmp/fog-db-and-user-setup.sql >>$error_log 2>&1
    errorStat $?
}
configureFOGService() {
    [[ ! -d $servicedst ]] && mkdir -p $servicedst >>$error_log 2>&1
    [[ ! -d $servicedst/etc ]] && mkdir -p $servicedst/etc >>$error_log 2>&1
    echo "<?php define('WEBROOT','${webdirdest}');" > $servicedst/etc/config.php
    startInitScript
}
configureNFS() {
    dots "Setting up NFS configuration file"
    if [[ -f "/etc/nfs.conf" ]]; then
        # Fix all set port=20048 back to default values
        sed -i '/^port=20048/ {s/^port=20048/# port=0/}' /etc/nfs.conf >>$error_log 2>&1
    fi
    # set port in nfs.conf.d directory
    if [[ -f "/etc/nfs.conf" && ! -d "/etc/nfs.conf.d/" ]]; then
        mkdir /etc/nfs.conf.d
    elif [[ -f "/usr/etc/nfs.conf" && ! -d "/usr/etc/nfs.conf.d/" ]]; then
        mkdir /usr/etc/nfs.conf.d
    fi
    if [[ -f "/etc/nfs.conf" && ! -f "/etc/nfs.conf.d/fog-nfs.conf" ]]; then
        cat > /etc/nfs.conf.d/fog-nfs.conf <<EOF
[mountd]
port=20048
EOF
    elif [[ -f "/usr/etc/nfs.conf" && ! -f "/usr/etc/nfs.conf.d/fog-nfs.conf" ]]; then
        cat > /usr/etc/nfs.conf.d/fog-nfs.conf <<EOF
[mountd]
port=20048
EOF
    fi
    errorStat $?
    dots "Setting up exports file"
    if [[ $blexports != 1 ]]; then
        echo "Skipped"
    else
        mv -fv "${nfsconfig}" "${nfsconfig}.${timestamp}" >>$error_log 2>&1
        userId=$(id -u $username)
        groupId=$(id -g $username)
        echo -e "$storageLocation *(ro,sync,no_wdelay,subtree_check,insecure_locks,all_squash,anonuid=${userId},anongid=${groupId},fsid=0)\n$storageLocation/dev *(rw,async,no_wdelay,subtree_check,all_squash,anonuid=${userId},anongid=${groupId},fsid=1)" > "$nfsconfig"
        diffconfig "${nfsconfig}"
        errorStat $?
        dots "Setting up and starting RPCBind"
        if [[ $systemctl == yes ]]; then
            systemctl is-enabled --quiet rpcbind && true || systemctl enable rpcbind.service >>$error_log 2>&1
            systemctl is-active --quiet rpcbind && systemctl stop rpcbind.service >>$error_log 2>&1 || true
            systemctl is-active --quiet rpcbind && true || systemctl start rpcbind.service >>$error_log 2>&1
            systemctl status rpcbind.service >>$error_log 2>&1
        else
            case $osid in
                1)
                    chkconfig rpcbind on >>$error_log 2>&1
                    $initdpath/rpcbind stop >>$error_log 2>&1
                    $initdpath/rpcbind start >>$error_log 2>&1
                    $initdpath/rpcbind status >>$error_log 2>&1
                    ;;
            esac
        fi
        errorStat $?
        dots "Setting up and starting NFS Server"
        for nfsItem in $nfsservice; do
            if [[ $systemctl == yes ]]; then
                systemctl is-enabled --quiet $nfsItem && true || systemctl enable $nfsItem >>$error_log 2>&1
                systemctl is-active --quiet $nfsItem && systemctl stop $nfsItem >>$error_log 2>&1 || true
                systemctl is-active --quiet $nfsItem && true || systemctl start $nfsItem >>$error_log 2>&1
                systemctl status $nfsItem >>$error_log 2>&1
            else
                case $osid in
                    1)
                        chkconfig $nfsItem on >>$error_log 2>&1
                        $initdpath/$nfsItem stop >>$error_log 2>&1
                        $initdpath/$nfsItem start >>$error_log 2>&1
                        $initdpath/$nfsItem status >>$error_log 2>&1
                        ;;
                    2)
                        sysv-rc-conf $nfsItem on >>$error_log 2>&1
                        $initdpath/nfs-kernel-server stop >>$error_log 2>&1
                        $initdpath/nfs-kernel-server start >>$error_log 2>&1
                        ;;
                esac
            fi
            [[ $? -eq 0 ]] && break
        done
        errorStat $?
    fi
}
configureSnapins() {
    dots "Setting up FOG Snapins"
    mkdir -p $snapindir >>$error_log 2>&1
    if [[ -d $snapindir ]]; then
        chmod -R 775 $snapindir
        chown -R $username:$apacheuser $snapindir
    fi
    errorStat $?
}
configureUsers() {
    userexists=0
    [[ -z $username || "x$username" == "xfog" ]] && username='fogproject'
    dots "Setting up $username user"
    getent passwd $username > /dev/null
    if [[ $? -eq 0 ]]; then
        if [[ ! -f "$fogprogramdir/.fogsettings" && ! -x /home/$username/warnfogaccount.sh ]]; then
            echo "Already exists"
            echo
            echo "The account \"$username\" already exists but this seems to be a"
            echo "fresh install. We highly recommend to NOT create this account"
            echo "as it is supposed to be a system account. It is not meant to be"
            echo "used to login and work on the server!"
            echo
            echo "Please remove the account \"$username\" manually before running"
            echo "the installer again. Run: userdel $username"
            echo
            exit 1
        else
            lastlog -u $username | tail -n1 | grep "\*\*.*\*\*" >/dev/null 2>&1
            if [[ $? -eq 1 ]]; then
                echo "Already exists"
                echo
                echo "The account \"$username\" already exists and has been used to"
                echo "log in to this server. We highly recommend you NOT use this"
                echo "account as it is supposed to be a system account!"
                echo
                echo "Please remove the account \"$username\" manually before running"
                echo "the installer again, or set the system username yourself."
                echo
                echo "To remove the account run: userdel $username"
                echo
                echo "To set a new service username run installer with:"
                echo "username=<usernameForSystem> ./installfog.sh -y"
                echo
                exit 1
            fi
        fi
        echo "Skipped"
    else
        useradd -s "/bin/bash" -d "/home/${username}" -m ${username} >>$error_log 2>&1
        errorStat $?
    fi
    if [[ ! -d /home/$username ]]; then
        echo "# It has been noticed that your $username home folder is missing, #"
        echo "#   has been deleted, or has been moved.                          #"
        echo "# This may cause issues with capturing images and snapin uploads. #"
        echo "# If you this move/delete was unintentional you can run:          #"
        echo " userdel $username"
        echo " useradd -s \"/bin/bash\" -d \"/home/$username\" -m \"$username\""
        #userdel $username
        #useradd -s "/bin/bash" -d "/home/${username}" -m ${username} >>$error_log 2>&1
        #errorStat $?
    fi
    dots "Locking $username as a system account"
    chsh -s /bin/bash $username >>$error_log 2>&1
    textmessage="You seem to be using the '$username' system account to logon and work \non your FOG Server system.\n\nIt's NOT recommended to use this account! Please create a new\naccount for administrative tasks.\n\nIf you re-run the installer it would reset the '$username' account\npassword and therefore lock you out of the system!\n\nTake care,\nyour FOGProject team"
    grep -q "exit 1" /home/$username/.bashrc >/dev/null 2>&1 || cat >>/home/$username/.bashrc <<EOF
echo -e "$textmessage"
exit 1
EOF
    mkdir -p /home/$username/.config/autostart/
    cat >/home/$username/.config/autostart/warnfogaccount.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Warn users to not use the $username account
Exec=/home/$username/warnfogaccount.sh
Comment=Warn users who use the $username system account to log on
EOF
    chown -R $username:$username /home/$username/.config/
    cat >/home/$username/warnfogaccount.sh <<EOF
#!/bin/bash
title="FOG System Account"
text="$textmessage"
z=\$(which zenity)
x=\$(which xmessage)
n=\$(which notify-send)
if [[ -x "\$z" ]]; then
    \$z --error --width=480 --text="\$text" --title="\$title"
elif [[ -x "\$x" ]]; then
    echo -e "\$text" | \$x -center -file -
else
    \$n -u critical "\$title" "\$(echo \$text | sed -e 's/ \\n/ /g')"
fi
EOF
    chmod 755 /home/$username/warnfogaccount.sh
    chown $username:$username /home/$username/warnfogaccount.sh
    errorStat $?
    dots "Setting up $username password"
    if [[ -z $password ]]; then
        # if we don't have a password from .fogsettings we check config.class.php as well
        if [[ -r $webdirdest/lib/fog/config.class.php ]]; then
            # extract password from old style config
            password=$(awk -F '"' -e '/TFTP_FTP_PASSWORD/,/);/{print $2}' $webdirdest/lib/fog/config.class.php | grep -v "^$")
            # if that didn't get us the password we try again new style
            [[ -z $password ]] && password=$(awk -F "'" -e '/TFTP_FTP_PASSWORD/{print $4}' $webdirdest/lib/fog/config.class.php)
        fi
    fi
    checkPasswordChars "$password"
    cnt=0
    ret=999
    while [[ $ret -ne 0 && $cnt -lt 10  ]]; do
        [[ -z $password || $ret -ne 999 ]] && password=$(generatePassword 20)
        echo -e "$password\n$password" | passwd $username >>$error_log 2>&1
        ret=$?
        let cnt+=1
    done
    errorStat $ret
    unset cnt
    unset ret
}
linkOptFogDir() {
    if [[ ! -h /var/log/fog ]]; then
        dots "Linking FOG Logs to Linux Logs"
        ln -s /opt/fog/log /var/log/fog >>$error_log 2>&1
        errorStat $?
    fi
    if [[ ! -h /etc/fog ]]; then
        dots "Linking FOG Service config /etc"
        ln -s /opt/fog/service/etc /etc/fog >>$error_log 2>&1
        errorStat $?
    fi
    local element='httpd'
    [[ $osid -eq 2 ]] && element='apache2'
    chmod -R 755 /var/log/$element >>$error_log 2>&1
    for i in $(find /var/log/ -type d -name 'php*fpm*' 2>>$error_log); do
        chmod -R 755 $i >>$error_log 2>&1
    done
    for i in $(find /var/log/ -type f -name 'php*fpm*' 2>>$error_log); do
        chmod -R 755 $i >>$error_log 2>&1
    done
}
configureStorage() {
    dots "Setting up storage"
    [[ ! -d $storageLocation ]] && mkdir $storageLocation >>$error_log 2>&1
    [[ ! -f $storageLocation/.mntcheck ]] && touch $storageLocation/.mntcheck >>$error_log 2>&1
    [[ ! -d $storageLocation/postdownloadscripts ]] && mkdir $storageLocation/postdownloadscripts >>$error_log 2>&1
    if [[ ! -f $storageLocation/postdownloadscripts/fog.postdownload ]]; then
        echo "#!/bin/bash" >"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "## This file serves as a starting point to call your custom postimaging scripts." >>"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "## <SCRIPTNAME> should be changed to the script you're planning to use." >>"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "## Syntax of post download scripts are" >>"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "#. \${postdownpath}<SCRIPTNAME>" >> "$storageLocation/postdownloadscripts/fog.postdownload"
    fi
    [[ ! -d $storageLocationCapture ]] && mkdir $storageLocationCapture >>$error_log 2>&1
    [[ ! -f $storageLocationCapture/.mntcheck ]] && touch $storageLocationCapture/.mntcheck >>$error_log 2>&1
    [[ ! -d $storageLocationCapture/postinitscripts ]] && mkdir $storageLocationCapture/postinitscripts >>$error_log 2>&1
    if [[ ! -f $storageLocationCapture/postinitscripts/fog.postinit ]]; then
        echo "#!/bin/bash" >"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "## This file serves as a starting point to call your custom pre-imaging/post init loading scripts." >>"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "## <SCRIPTNAME> should be changed to the script you're planning to use." >>"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "## Syntax of post init scripts are" >>"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "#. \${postinitpath}<SCRIPTNAME>" >>"$storageLocationCapture/postinitscripts/fog.postinit"
    else
        (head -1 "$storageLocationCapture/postinitscripts/fog.postinit" | grep -q '^#!/bin/bash') || sed -i '1i#!/bin/bash' "$storageLocationCapture/postinitscripts/fog.postinit" >/dev/null 2>&1
    fi
    chmod -R 775 $storageLocation $storageLocationCapture >>$error_log 2>&1
    chown -R $username:$username $storageLocation $storageLocationCapture >>$error_log 2>&1
    errorStat $?
}
clearScreen() {
    clear
}
writeUpdateFile() {
    tmpDte=$(date +%c)
    replace='s/[]"\/$&*.^|[]/\\&/g';
    escversion=$(echo $version | sed -e $replace)
    esctmpDte=$(echo $tmpDate | sed -e $replace)
    escipaddress=$(echo $ipaddress | sed -e $replace)
    escinterface=$(echo $interface | sed -e $replace)
    escsubmask=$(echo $submask | sed -e $replace)
    eschostname=$(echo $hostname | sed -e $replace)
    escrouteraddress=$(echo $routeraddress | sed -e $replace)
    escplainrouter=$(echo $plainrouter | sed -e $replace)
    escdnsaddress=$(echo $dnsaddress | sed -e $replace)
    escpassword=$(echo $password | sed -e $replace)
    escosid=$(echo $osid | sed -e $replace)
    escosname=$(echo $osname | sed -e $replace)
    escdodhcp=$(echo $dodhcp | sed -e $replace)
    escbldhcp=$(echo $bldhcp | sed -e $replace)
    escdhcpd=$(echo $dhcpd | sed -e $replace)
    escblexports=$(echo $blexports | sed -e $replace)
    escinstalltype=$(echo $installtype | sed -e $replace)
    escsnmysqluser=$(echo $snmysqluser | sed -e $replace)
    escsnmysqlpass=$(echo "$snmysqlpass" | sed -e s/\'/\'\"\'\"\'/g)  # replace every ' with '"'"' for full bash escaping
    sedescsnmysqlpass=$(echo "$escsnmysqlpass" | sed -e 's/[\&/]/\\&/g')  # then prefix every \ & and / with \ for sed escaping
    escsnmysqlhost=$(echo $snmysqlhost | sed -e $replace)
    escmysqldbname=$(echo $mysqldbname | sed -e $replace)
    escinstalllang=$(echo $installlang | sed -e $replace)
    escstorageLocation=$(echo $storageLocation | sed -e $replace)
    escfogupdateloaded=$(echo $fogupdateloaded | sed -e $replace)
    escusername=$(echo $username | sed -e $replace)
    escdocroot=$(echo $docroot | sed -e $replace)
    escwebroot=$(echo $webroot | sed -e $replace)
    esccaCreated=$(echo $caCreated | sed -e $replace)
    eschttpproto=$(echo $httpproto | sed -e $replace)
    escstartrange=$(echo $startrange | sed -e $replace)
    escendrange=$(echo $endrange | sed -e $replace)
    escpackages=$(echo $packages | sed -e $replace)
    escnoTftpBuild=$(echo $noTftpBuild | sed -e $replace)
    esctftpAdvOpts=$(echo $tftpAdvOpts | sed -e $replace)
    escsslpath=$(echo $sslpath | sed -e $replace)
    escbackupPath=$(echo $backupPath | sed -e $replace)
    escphp_ver=$(echo $php_ver | sed -e $replace)
    escsslprivkey=$(echo $sslprivkey | sed -e $replace)
    [[ -z $copybackold || $copybackold -lt 1 ]] && copybackold=0
    if [[ -f $fogprogramdir/.fogsettings ]]; then
        grep -q "^## Start of FOG Settings" $fogprogramdir/.fogsettings || grep -q "^## Version:.*" $fogprogramdir/.fogsettings
        if [[ $? == 0 ]]; then
            grep -q "^## Version:.*$" $fogprogramdir/.fogsettings && \
                sed -i "s/^## Version:.*/## Version: $escversion/g" $fogprogramdir/.fogsettings || \
                echo "## Version: $version" >> $fogprogramdir/.fogsettings
            grep -q "ipaddress=" $fogprogramdir/.fogsettings && \
                sed -i "s/ipaddress=.*/ipaddress='$escipaddress'/g" $fogprogramdir/.fogsettings || \
                echo "ipaddress='$ipaddress'" >> $fogprogramdir/.fogsettings
            grep -q "copybackold=" $fogprogramdir/.fogsettings && \
                sed -i "s/copybackold=.*/copybackold='$copybackold'/g" $fogprogramdir/.fogsettings || \
                echo "copybackold='$copybackold'" >> $fogprogramdir/.fogsettings
            grep -q "interface=" $fogprogramdir/.fogsettings && \
                sed -i "s/interface=.*/interface='$escinterface'/g" $fogprogramdir/.fogsettings || \
                echo "interface='$interface'" >> $fogprogramdir/.fogsettings
            grep -q "submask=" $fogprogramdir/.fogsettings && \
                sed -i "s/submask=.*/submask='$escsubmask'/g" $fogprogramdir/.fogsettings || \
                echo "submask='$submask'" >> $fogprogramdir/.fogsettings
            grep -q "hostname=" $fogprogramdir/.fogsettings && \
                sed -i "s/hostname=.*/hostname='$eschostname'/g" $fogprogramdir/.fogsettings || \
                echo "hostname='$hostname'" >> $fogprogramdir/.fogsettings
            grep -q "routeraddress=" $fogprogramdir/.fogsettings && \
                sed -i "s/routeraddress=.*/routeraddress='$escrouteraddress'/g" $fogprogramdir/.fogsettings || \
                echo "routeraddress='$routeraddress'" >> $fogprogramdir/.fogsettings
            grep -q "plainrouter=" $fogprogramdir/.fogsettings && \
                sed -i "s/plainrouter=.*/plainrouter='$escplainrouter'/g" $fogprogramdir/.fogsettings || \
                echo "plainrouter='$plainrouter'" >> $fogprogramdir/.fogsettings
            grep -q "dnsaddress=" $fogprogramdir/.fogsettings && \
                sed -i "s/dnsaddress=.*/dnsaddress='$escdnsaddress'/g" $fogprogramdir/.fogsettings || \
                echo "dnsaddress='$dnsaddress'" >> $fogprogramdir/.fogsettings
            grep -q "password=" $fogprogramdir/.fogsettings && \
                sed -i "s/password=.*/password='$escpassword'/g" $fogprogramdir/.fogsettings || \
                echo "password='$password'" >> $fogprogramdir/.fogsettings
            grep -q "osid=" $fogprogramdir/.fogsettings && \
                sed -i "s/osid=.*/osid='$osid'/g" $fogprogramdir/.fogsettings || \
                echo "osid='$osid'" >> $fogprogramdir/.fogsettings
            grep -q "osname=" $fogprogramdir/.fogsettings && \
                sed -i "s/osname=.*/osname='$escosname'/g" $fogprogramdir/.fogsettings || \
                echo "osname='$osname'" >> $fogprogramdir/.fogsettings
            grep -q "dodhcp=" $fogprogramdir/.fogsettings && \
                sed -i "s/dodhcp=.*/dodhcp='$escdodhcp'/g" $fogprogramdir/.fogsettings || \
                echo "dodhcp='$dodhcp'" >> $fogprogramdir/.fogsettings
            grep -q "bldhcp=" $fogprogramdir/.fogsettings && \
                sed -i "s/bldhcp=.*/bldhcp='$escbldhcp'/g" $fogprogramdir/.fogsettings || \
                echo "bldhcp='$bldhcp'" >> $fogprogramdir/.fogsettings
            grep -q "dhcpd=" $fogprogramdir/.fogsettings && \
                sed -i "s/dhcpd=.*/dhcpd='$escdhcpd'/g" $fogprogramdir/.fogsettings || \
                echo "dhcpd='$dhcpd'" >> $fogprogramdir/.fogsettings
            grep -q "blexports=" $fogprogramdir/.fogsettings && \
                sed -i "s/blexports=.*/blexports='$escblexports'/g" $fogprogramdir/.fogsettings || \
                echo "blexports='$blexports'" >> $fogprogramdir/.fogsettings
            grep -q "installtype=" $fogprogramdir/.fogsettings && \
                sed -i "s/installtype=.*/installtype='$escinstalltype'/g" $fogprogramdir/.fogsettings || \
                echo "installtype='$installtype'" >> $fogprogramdir/.fogsettings
            grep -q "snmysqluser=" $fogprogramdir/.fogsettings && \
                sed -i "s/snmysqluser=.*/snmysqluser='$escsnmysqluser'/g" $fogprogramdir/.fogsettings || \
                echo "snmysqluser='$snmysqluser'" >> $fogprogramdir/.fogsettings
            grep -q "snmysqlpass=" $fogprogramdir/.fogsettings && \
                sed -i "s/snmysqlpass=.*/snmysqlpass='$sedescsnmysqlpass'/g" $fogprogramdir/.fogsettings || \
                echo "snmysqlpass='$escsnmysqlpass'" >> $fogprogramdir/.fogsettings
            grep -q "snmysqlhost=" $fogprogramdir/.fogsettings && \
                sed -i "s/snmysqlhost=.*/snmysqlhost='$escsnmysqlhost'/g" $fogprogramdir/.fogsettings || \
                echo "snmysqlhost='$snmysqlhost'" >> $fogprogramdir/.fogsettings
            grep -q "mysqldbname=" $fogprogramdir/.fogsettings && \
                sed -i "s/mysqldbname=.*/mysqldbname='$escmysqldbname'/g" $fogprogramdir/.fogsettings || \
                echo "mysqldbname='$mysqldbname'" >> $fogprogramdir/.fogsettings
            grep -q "installlang=" $fogprogramdir/.fogsettings && \
                sed -i "s/installlang=.*/installlang='$escinstalllang'/g" $fogprogramdir/.fogsettings || \
                echo "installlang='$installlang'" >> $fogprogramdir/.fogsettings
            grep -q "storageLocation=" $fogprogramdir/.fogsettings && \
                sed -i "s/storageLocation=.*/storageLocation='$escstorageLocation'/g" $fogprogramdir/.fogsettings || \
                echo "storageLocation='$storageLocation'" >> $fogprogramdir/.fogsettings
            grep -q "fogupdateloaded=" $fogprogramdir/.fogsettings && \
                sed -i "s/fogupdateloaded=.*/fogupdateloaded=$escfogupdateloaded/g" $fogprogramdir/.fogsettings || \
                echo "fogupdateloaded=$fogupdateloaded" >> $fogprogramdir/.fogsettings
            grep -q "storageftpuser=" $fogprogramdir/.fogsettings && \
                sed -i "/storageftpuser=/d" $fogprogramdir/.fogsettings
            grep -q "storageftppass=" $fogprogramdir/.fogsettings && \
                sed -i "/storageftppass=/d" $fogprogramdir/.fogsettings
            grep -q "username=" $fogprogramdir/.fogsettings && \
                sed -i "s/username=.*/username='$escusername'/g" $fogprogramdir/.fogsettings || \
                echo "username='$username'" >> $fogprogramdir/.fogsettings
            grep -q "docroot=" $fogprogramdir/.fogsettings && \
                sed -i "s/docroot=.*/docroot='$escdocroot'/g" $fogprogramdir/.fogsettings || \
                echo "docroot='$docroot'" >> $fogprogramdir/.fogsettings
            grep -q "webroot=" $fogprogramdir/.fogsettings && \
                sed -i "s/webroot=.*/webroot='$escwebroot'/g" $fogprogramdir/.fogsettings || \
                echo "webroot='$webroot'" >> $fogprogramdir/.fogsettings
            grep -q "caCreated=" $fogprogramdir/.fogsettings && \
                sed -i "s/caCreated=.*/caCreated='$esccaCreated'/g" $fogprogramdir/.fogsettings || \
                echo "caCreated='$caCreated'" >> $fogprogramdir/.fogsettings
            grep -q "httpproto=" $fogprogramdir/.fogsettings && \
                sed -i "s/httpproto=.*/httpproto='$eschttpproto'/g" $fogprogramdir/.fogsettings || \
                echo "httpproto='$httpproto'" >> $fogprogramdir/.fogsettings
            grep -q "startrange=" $fogprogramdir/.fogsettings && \
                sed -i "s/startrange=.*/startrange='$escstartrange'/g" $fogprogramdir/.fogsettings || \
                echo "startrange='$startrange'" >> $fogprogramdir/.fogsettings
            grep -q "endrange=" $fogprogramdir/.fogsettings && \
                sed -i "s/endrange=.*/endrange='$escendrange'/g" $fogprogramdir/.fogsettings || \
                echo "endrange='$endrange'" >> $fogprogramdir/.fogsettings
            grep -q "bootfilename=" $fogprogramdir/.fogsettings && \
                sed -i "/bootfilename=.*$/d" $fogprogramdir/.fogsettings
            grep -q "packages=" $fogprogramdir/.fogsettings && \
                sed -i "s/packages=.*/packages='$escpackages'/g" $fogprogramdir/.fogsettings || \
                echo "packages='$packages'" >> $fogprogramdir/.fogsettings
            grep -q "noTftpBuild=" $fogprogramdir/.fogsettings && \
                sed -i "s/noTftpBuild=.*/noTftpBuild='$escnoTftpBuild'/g" $fogprogramdir/.fogsettings || \
                echo "noTftpBuild='$noTftpBuild'" >> $fogprogramdir/.fogsettings
            grep -q "tftpAdvOpts=" $fogprogramdir/.fogsettings && \
                sed -i "s/tftpAdvOpts=.*/tftpAdvOpts='$esctftpAdvOpts'/g" $fogprogramdir/.fogsettings || \
                echo "tftpAdvOpts='$tftpAdvOpts'" >> $fogprogramdir/.fogsettings
            grep -q "notpxedefaultfile=" $fogprogramdir/.fogsettings && \
                sed -i "/notpxedefaultfile=.*$/d" $fogprogramdir/.fogsettings
            grep -q "sslpath=" $fogprogramdir/.fogsettings && \
                sed -i "s/sslpath=.*/sslpath='$escsslpath'/g" $fogprogramdir/.fogsettings || \
                echo "sslpath='$sslpath'" >> $fogprogramdir/.fogsettings
            grep -q "backupPath=" $fogprogramdir/.fogsettings && \
                sed -i "s/backupPath=.*/backupPath='$escbackupPath'/g" $fogprogramdir/.fogsettings || \
                echo "backupPath='$backupPath'" >> $fogprogramdir/.fogsettings
            grep -q "php_ver=" $fogprogramdir/.fogsettings && \
                sed -i "s/php_ver=.*/php_ver='$php_ver'/g" $fogprogramdir/.fogsettings || \
                echo "php_ver='$php_ver'" >> $fogprogramdir/.fogsettings
            grep -q "php_verAdds=" $fogprogramdir/.fogsettings && \
                sed -i "/php_verAdds=/d" $fogprogramdir/.fogsettings
            grep -q "sslprivkey=" $fogprogramdir/.fogsettings && \
                sed -i "s/sslprivkey=.*/sslprivkey='$escsslprivkey'/g" $fogprogramdir/.fogsettings || \
                echo "sslprivkey='$sslprivkey'" >> $fogprogramdir/.fogsettings
            grep -q "sendreports=" $fogprogramdir/.fogsettings && \
                sed -i "s/sendreports=.*/sendreports='$sendreports'/g" $fogprogramdir/.fogsettings || \
                echo "sendreports='$sendreports'" >> $fogprogramdir/.fogsettings
        else
            echo "## Start of FOG Settings" > "$fogprogramdir/.fogsettings"
            echo "## Created by the FOG Installer" >> "$fogprogramdir/.fogsettings"
            echo "## Find more information about this file in the FOG Project wiki:" >> "$fogprogramdir/.fogsettings"
            echo "##     https://wiki.fogproject.org/wiki/index.php?title=.fogsettings" >> "$fogprogramdir/.fogsettings"
            echo "## Version: $version" >> "$fogprogramdir/.fogsettings"
            echo "## Install time: $tmpDte" >> "$fogprogramdir/.fogsettings"
            echo "ipaddress='$ipaddress'" >> "$fogprogramdir/.fogsettings"
            echo "copybackold='$copybackold'" >> "$fogprogramdir/.fogsettings"
            echo "interface='$interface'" >> "$fogprogramdir/.fogsettings"
            echo "submask='$submask'" >> "$fogprogramdir/.fogsettings"
            echo "hostname='$hostname'" >> "$fogprogramdir/.fogsettings"
            echo "routeraddress='$routeraddress'" >> "$fogprogramdir/.fogsettings"
            echo "plainrouter='$plainrouter'" >> "$fogprogramdir/.fogsettings"
            echo "dnsaddress='$dnsaddress'" >> "$fogprogramdir/.fogsettings"
            echo "username='$username'" >> "$fogprogramdir/.fogsettings"
            echo "password='$password'" >> "$fogprogramdir/.fogsettings"
            echo "osid='$osid'" >> "$fogprogramdir/.fogsettings"
            echo "osname='$osname'" >> "$fogprogramdir/.fogsettings"
            echo "dodhcp='$dodhcp'" >> "$fogprogramdir/.fogsettings"
            echo "bldhcp='$bldhcp'" >> "$fogprogramdir/.fogsettings"
            echo "dhcpd='$dhcpd'" >> "$fogprogramdir/.fogsettings"
            echo "blexports='$blexports'" >> "$fogprogramdir/.fogsettings"
            echo "installtype='$installtype'" >> "$fogprogramdir/.fogsettings"
            echo "snmysqluser='$snmysqluser'" >> "$fogprogramdir/.fogsettings"
            echo "snmysqlpass='$escsnmysqlpass'" >> "$fogprogramdir/.fogsettings"
            echo "snmysqlhost='$snmysqlhost'" >> "$fogprogramdir/.fogsettings"
            echo "mysqldbname='$mysqldbname'" >> "$fogprogramdir/.fogsettings"
            echo "installlang='$installlang'" >> "$fogprogramdir/.fogsettings"
            echo "storageLocation='$storageLocation'" >> "$fogprogramdir/.fogsettings"
            echo "fogupdateloaded=1" >> "$fogprogramdir/.fogsettings"
            echo "docroot='$docroot'" >> "$fogprogramdir/.fogsettings"
            echo "webroot='$webroot'" >> "$fogprogramdir/.fogsettings"
            echo "caCreated='$caCreated'" >> "$fogprogramdir/.fogsettings"
            echo "httpproto='$httpproto'" >> "$fogprogramdir/.fogsettings"
            echo "startrange='$startrange'" >> "$fogprogramdir/.fogsettings"
            echo "endrange='$endrange'" >> "$fogprogramdir/.fogsettings"
            echo "packages='$packages'" >> "$fogprogramdir/.fogsettings"
            echo "noTftpBuild='$noTftpBuild'" >> "$fogprogramdir/.fogsettings"
            echo "tftpAdvOpts='$tftpAdvOpts'" >> "$fogprogramdir/.fogsettings"
            echo "sslpath='$sslpath'" >> "$fogprogramdir/.fogsettings"
            echo "backupPath='$backupPath'" >> "$fogprogramdir/.fogsettings"
            echo "php_ver='$php_ver'" >> "$fogprogramdir/.fogsettings"
            echo "sslprivkey='$sslprivkey'" >> $fogprogramdir/.fogsettings
            echo "sendreports='$sendreports'" >> $fogprogramdir/.fogsettings
            echo "## End of FOG Settings" >> "$fogprogramdir/.fogsettings"
        fi
    else
        echo "## Start of FOG Settings" > "$fogprogramdir/.fogsettings"
        echo "## Created by the FOG Installer" >> "$fogprogramdir/.fogsettings"
        echo "## Find more information about this file in the FOG Project wiki:" >> "$fogprogramdir/.fogsettings"
        echo "##     https://wiki.fogproject.org/wiki/index.php?title=.fogsettings" >> "$fogprogramdir/.fogsettings"
        echo "## Version: $version" >> "$fogprogramdir/.fogsettings"
        echo "## Install time: $tmpDte" >> "$fogprogramdir/.fogsettings"
        echo "ipaddress='$ipaddress'" >> "$fogprogramdir/.fogsettings"
        echo "copybackold='$copybackold'" >> "$fogprogramdir/.fogsettings"
        echo "interface='$interface'" >> "$fogprogramdir/.fogsettings"
        echo "submask='$submask'" >> "$fogprogramdir/.fogsettings"
        echo "hostname='$hostname'" >> "$fogprogramdir/.fogsettings"
        echo "routeraddress='$routeraddress'" >> "$fogprogramdir/.fogsettings"
        echo "plainrouter='$plainrouter'" >> "$fogprogramdir/.fogsettings"
        echo "dnsaddress='$dnsaddress'" >> "$fogprogramdir/.fogsettings"
        echo "username='$username'" >> "$fogprogramdir/.fogsettings"
        echo "password='$password'" >> "$fogprogramdir/.fogsettings"
        echo "osid='$osid'" >> "$fogprogramdir/.fogsettings"
        echo "osname='$osname'" >> "$fogprogramdir/.fogsettings"
        echo "dodhcp='$dodhcp'" >> "$fogprogramdir/.fogsettings"
        echo "bldhcp='$bldhcp'" >> "$fogprogramdir/.fogsettings"
        echo "dhcpd='$dhcpd'" >> "$fogprogramdir/.fogsettings"
        echo "blexports='$blexports'" >> "$fogprogramdir/.fogsettings"
        echo "installtype='$installtype'" >> "$fogprogramdir/.fogsettings"
        echo "snmysqluser='$snmysqluser'" >> "$fogprogramdir/.fogsettings"
        echo "snmysqlpass='$escsnmysqlpass'" >> "$fogprogramdir/.fogsettings"
        echo "snmysqlhost='$snmysqlhost'" >> "$fogprogramdir/.fogsettings"
        echo "mysqldbname='$mysqldbname'" >> "$fogprogramdir/.fogsettings"
        echo "installlang='$installlang'" >> "$fogprogramdir/.fogsettings"
        echo "storageLocation='$storageLocation'" >> "$fogprogramdir/.fogsettings"
        echo "fogupdateloaded=1" >> "$fogprogramdir/.fogsettings"
        echo "docroot='$docroot'" >> "$fogprogramdir/.fogsettings"
        echo "webroot='$webroot'" >> "$fogprogramdir/.fogsettings"
        echo "caCreated='$caCreated'" >> "$fogprogramdir/.fogsettings"
        echo "httpproto='$httpproto'" >> "$fogprogramdir/.fogsettings"
        echo "startrange='$startrange'" >> "$fogprogramdir/.fogsettings"
        echo "endrange='$endrange'" >> "$fogprogramdir/.fogsettings"
        echo "packages='$packages'" >> "$fogprogramdir/.fogsettings"
        echo "noTftpBuild='$noTftpBuild'" >> "$fogprogramdir/.fogsettings"
        echo "tftpAdvOpts='$tftpAdvOpts'" >> "$fogprogramdir/.fogsettings"
        echo "sslpath='$sslpath'" >> "$fogprogramdir/.fogsettings"
        echo "backupPath='$backupPath'" >> "$fogprogramdir/.fogsettings"
        echo "php_ver='$php_ver'" >> "$fogprogramdir/.fogsettings"
        echo "sslprivkey='$sslprivkey'" >> $fogprogramdir/.fogsettings
        echo "sendreports='$sendreports'" >> $fogprogramdir/.fogsettings
        echo "## End of FOG Settings" >> "$fogprogramdir/.fogsettings"
    fi
    # Remove world-readable permissions
    chmod 0600 "${fogprogramdir}/.fogsettings" >>$error_log 2>&1
    chown "${username}" "${fogprogramdir}/.fogsettings" >>$error_log 2>&1
}
displayBanner() {
    echo
    echo
    echo "   +------------------------------------------+"
    echo "   |     ..#######:.    ..,#,..     .::##::.  |"
    echo "   |.:######          .:;####:......;#;..     |"
    echo "   |...##...        ...##;,;##::::.##...      |"
    echo "   |   ,#          ...##.....##:::##     ..:: |"
    echo "   |   ##    .::###,,##.   . ##.::#.:######::.|"
    echo "   |...##:::###::....#. ..  .#...#. #...#:::. |"
    echo "   |..:####:..    ..##......##::##  ..  #     |"
    echo "   |    #  .      ...##:,;##;:::#: ... ##..   |"
    echo "   |   .#  .       .:;####;::::.##:::;#:..    |"
    echo "   |    #                     ..:;###..       |"
    echo "   |                                          |"
    echo "   +------------------------------------------+"
    echo "   |      Free Computer Imaging Solution      |"
    echo "   +------------------------------------------+"
    echo "   |  Credits: http://fogproject.org/Credits  |"
    echo "   |       http://fogproject.org/Credits      |"
    echo "   |       Released under GPL Version 3       |"
    echo "   +------------------------------------------+"
    echo
    echo
}
createSSLCA() {
    if [[ -z $sslpath ]]; then
        [[ -d /opt/fog/snapins/CA && -d /opt/fog/snapins/ssl ]] && mv /opt/fog/snapins/CA /opt/fog/snapins/ssl/
        sslpath='/opt/fog/snapins/ssl/'
    fi
    if [[ $recreateCA == yes || $caCreated != yes || ! -e $sslpath/CA || ! -e $sslpath/CA/.fogCA.key ]]; then
        mkdir -p $sslpath/CA >>$error_log 2>&1
        dots "Creating SSL CA"
        openssl genrsa -out $sslpath/CA/.fogCA.key 4096 >>$error_log 2>&1
        openssl req -x509 -new -sha512 -nodes -key $sslpath/CA/.fogCA.key -days 3650 -out $sslpath/CA/.fogCA.pem >>$error_log 2>&1 << EOF
.
.
.
.
.
FOG Server CA
.
EOF
        errorStat $?
    fi
    [[ -z $sslprivkey ]] && sslprivkey="$sslpath/.srvprivate.key"
    if [[ $recreateKeys == yes || $recreateCA == yes || $caCreated != yes || ! -e $sslpath || ! -e $sslprivkey ]]; then
        dots "Creating SSL Private Key"
        if [[ $(validip $ipaddress) -ne 0 ]]; then
            echo -e "\n"
            echo "  You seem to be using a DNS name instead of an IP address."
            echo "  This would cause an error when generating SSL key and certs"
            echo "  and so we will stop here! Please adjust variable 'ipaddress'"
            echo "  in .fogsettings file if this is an update and make sure you"
            echo "  provide an IP address when re-running the installer."
            exit 1
        fi
        mkdir -p $sslpath >>$error_log 2>&1
        openssl genrsa -out $sslprivkey 4096 >>$error_log 2>&1
        cat > $sslpath/req.cnf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = yes
[req_distinguished_name]
CN = $ipaddress
[v3_req]
subjectAltName = @alt_names
[alt_names]
IP.1 = $ipaddress
DNS.1 = $hostname
EOF
        openssl req -new -sha512 -key $sslprivkey -out $sslpath/fog.csr -config $sslpath/req.cnf >>$error_log 2>&1 << EOF
$ipaddress
EOF
        errorStat $?
    fi
    [[ ! -e $sslpath/.srvprivate.key ]] && ln -sf $sslprivkey $sslpath/.srvprivate.key >>$error_log 2>&1
    dots "Creating SSL Certificate"
    mkdir -p $webdirdest/management/other/ssl >>$error_log 2>&1
    cat > $sslpath/ca.cnf << EOF
[v3_ca]
subjectAltName = @alt_names
[alt_names]
IP.1 = $ipaddress
DNS.1 = $hostname
EOF
    openssl x509 -req -in $sslpath/fog.csr -CA $sslpath/CA/.fogCA.pem -CAkey $sslpath/CA/.fogCA.key -CAcreateserial -out $webdirdest/management/other/ssl/srvpublic.crt -days 3650 -extensions v3_ca -extfile $sslpath/ca.cnf >>$error_log 2>&1
    errorStat $?
    dots "Creating auth pub key and cert"
    cp $sslpath/CA/.fogCA.pem $webdirdest/management/other/ca.cert.pem >>$error_log 2>&1
    openssl x509 -outform der -in $webdirdest/management/other/ca.cert.pem -out $webdirdest/management/other/ca.cert.der >>$error_log 2>&1
    errorStat $?
    dots "Resetting SSL Permissions"
    chown -R $apacheuser:$apacheuser $webdirdest/management/other >>$error_log 2>&1
    errorStat $?
    [[ $httpproto == https ]] && sslenabled=" (SSL)" || sslenabled=" (no SSL)"
    dots "Setting up Apache virtual host${sslenabled}"
    case $novhost in
        [Yy]|[Yy][Ee][Ss])
            echo "Skipped"
            ;;
        *)
            if [[ $osid -eq 2 ]]; then
                a2dissite 001-fog >>$error_log 2>&1
                a2ensite 000-default >>$error_log 2>&1
            fi
            mv -fv "${etcconf}" "${etcconf}.${timestamp}" >>$error_log 2>&1
            echo "<VirtualHost *:80>" > "$etcconf"
            echo "    <FilesMatch \"\.php\$\">" >> "$etcconf"
            if [[ $osid -eq 1 && $OSVersion -lt 7 ]]; then
                echo "        SetHandler application/x-httpd-php" >> "$etcconf"
            else
                echo "        SetHandler \"proxy:fcgi://127.0.0.1:9000/\"" >> "$etcconf"
            fi
            echo "    </FilesMatch>" >> "$etcconf"
            echo "    KeepAlive Off" >> "$etcconf"
            echo "    ServerName $ipaddress" >> "$etcconf"
            echo "    ServerAlias $hostname" >> "$etcconf"
            echo "    DocumentRoot $docroot" >> "$etcconf"
            if [[ $httpproto == https ]]; then
                echo "    RewriteEngine On" >> "$etcconf"
                echo "    RewriteCond %{REQUEST_METHOD} ^(TRACE|TRACK)" >> "$etcconf"
                echo "    RewriteRule .* - [F]" >> "$etcconf"
                echo "    RewriteRule /management/other/ca.cert.der$ - [L]" >> "$etcconf"
                echo "    RewriteCond %{HTTPS} off" >> "$etcconf"
                echo "    RewriteRule (.*) https://%{HTTP_HOST}/\$1 [R,L]" >> "$etcconf"
                echo "</VirtualHost>" >> "$etcconf"
                echo "<VirtualHost *:443>" >> "$etcconf"
                echo "    KeepAlive Off" >> "$etcconf"
                echo "    <FilesMatch \"\.php\$\">" >> "$etcconf"
                if [[ $osid -eq 1 && $OSVersion -lt 7 ]]; then
                    echo "        SetHandler application/x-httpd-php" >> "$etcconf"
                else
                    echo "        SetHandler \"proxy:fcgi://127.0.0.1:9000/\"" >> "$etcconf"
                fi
                echo "    </FilesMatch>" >> "$etcconf"
                echo "    ServerName $ipaddress" >> "$etcconf"
                echo "    ServerAlias $hostname" >> "$etcconf"
                echo "    DocumentRoot $docroot" >> "$etcconf"
                echo "    SSLEngine On" >> "$etcconf"
                echo "    SSLProtocol -all +TLSv1.2" >> "$etcconf"
                echo "    SSLCipherSuite HIGH:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305:!MEDIUM:!LOW" >> "$etcconf"
                echo "    SSLHonorCipherOrder On" >> "$etcconf"
                echo "    SSLSessionTickets Off" >> "$etcconf"
                echo "    SSLCertificateFile $webdirdest/management/other/ssl/srvpublic.crt" >> "$etcconf"
                echo "    SSLCertificateKeyFile $sslprivkey" >> "$etcconf"
                echo "    SSLCACertificateFile $webdirdest/management/other/ca.cert.pem" >> "$etcconf"
                echo "    <Directory $webdirdest>" >> "$etcconf"
                echo "        DirectoryIndex index.php index.html index.htm" >> "$etcconf"
                echo "    </Directory>" >> "$etcconf"
                echo "    Timeout 600" >> "$etcconf"
                echo "    ProxyTimeout 600" >> "$etcconf"
                echo "    RewriteEngine On" >> "$etcconf"
                echo "    RewriteCond %{REQUEST_METHOD} ^(TRACE|TRACK)" >> "$etcconf"
                echo "    RewriteRule .* - [F]" >> "$etcconf"
                echo "    RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} !-f" >> "$etcconf"
                echo "    RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} !-d" >> "$etcconf"
                echo "    RewriteRule ^/fog/(.*)$ /fog/api/index.php [QSA,L]" >> "$etcconf"
                echo "</VirtualHost>" >> "$etcconf"
            else
                echo "    <Directory $webdirdest>" >> "$etcconf"
                echo "        DirectoryIndex index.php index.html index.htm" >> "$etcconf"
                echo "    </Directory>" >> "$etcconf"
                echo "    Timeout 600" >> "$etcconf"
                echo "    ProxyTimeout 600" >> "$etcconf"
                echo "    RewriteEngine On" >> "$etcconf"
                echo "    RewriteCond %{REQUEST_METHOD} ^(TRACE|TRACK)" >> "$etcconf"
                echo "    RewriteRule .* - [F]" >> "$etcconf"
                echo "    RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} !-f" >> "$etcconf"
                echo "    RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} !-d" >> "$etcconf"
                echo "    RewriteRule ^/fog/(.*)$ /fog/api/index.php [QSA,L]" >> "$etcconf"
                echo "</VirtualHost>" >> "$etcconf"
            fi
            diffconfig "${etcconf}"
            errorStat $?
            ln -s $webdirdest $webdirdest/ >>$error_log 2>&1
            case $osid in
                1)
                    phpfpmconf='/etc/php-fpm.d/www.conf';
                    ;;
                2)
                    phpfpmconf="/etc/php/$php_ver/fpm/pool.d/www.conf"
                    ;;
                3)
                    phpfpmconf='/etc/php/php-fpm.d/www.conf'
                    ;;
            esac
            if [[ -n $phpfpmconf ]]; then
                sed -i 's/listen = .*/listen = 127.0.0.1:9000/g' $phpfpmconf >>$error_log 2>&1
                sed -i 's/^[;]pm\.max_requests = .*/pm.max_requests = 2000/g' $phpfpmconf >>$error_log 2>&1
                sed -i 's/^[;]php_admin_value\[memory_limit\] = .*/php_admin_value[memory_limit] = 256M/g' $phpfpmconf >>$error_log 2>&1
                sed -i 's/pm\.max_children = .*/pm.max_children = 50/g' $phpfpmconf >>$error_log 2>&1
                sed -i 's/pm\.min_spare_servers = .*/pm.min_spare_servers = 5/g' $phpfpmconf >>$error_log 2>&1
                sed -i 's/pm\.max_spare_servers = .*/pm.max_spare_servers = 10/g' $phpfpmconf >>$error_log 2>&1
                sed -i 's/pm\.start_servers = .*/pm.start_servers = 5/g' $phpfpmconf >>$error_log 2>&1
            fi
            if [[ $osid -eq 2 ]]; then
                a2enmod php >>$error_log 2>&1
                a2enmod proxy_fcgi setenvif >>$error_log 2>&1
                a2enmod rewrite >>$error_log 2>&1
                a2enmod ssl >>$error_log 2>&1
                a2ensite "001-fog" >>$error_log 2>&1
                a2dissite "000-default" >>$error_log 2>&1
            fi
            ;;
    esac
    dots "Starting and checking status of web services"
    case $systemctl in
        yes)
            case $osid in
                2)
                    systemctl is-active --quiet apache2 $phpfpm && systemctl stop apache2 $phpfpm >>$error_log 2>&1 || true
                    systemctl is-active --quiet apache2 $phpfpm && true || systemctl start apache2 $phpfpm >>$error_log 2>&1
                    systemctl status apache2 $phpfpm >>$error_log 2>&1
                    ;;
                *)
                    systemctl is-active --quiet httpd php-fpm && systemctl stop httpd php-fpm >>$error_log 2>&1 || true
                    sleep 1
                    systemctl is-active --quiet httpd php-fpm && true || systemctl start httpd php-fpm >>$error_log 2>&1
                    sleep 1
                    systemctl status httpd php-fpm >>$error_log 2>&1
                    ;;
            esac
            ;;
        *)
            case $osid in
                2)
                    service apache2 stop >>$error_log 2>&1
                    service apache2 start >>$error_log 2>&1
                    service $phpfpm stop >>$error_log 2>&1
                    service $phpfpm start >>$error_log 2>&1
                    service apache2 status >>$error_log 2>&1
                    service $phpfpm status >>$error_log 2>&1
                    ;;
                *)
                    service httpd stop >>$error_log 2>&1
                    service httpd start >>$error_log 2>&1
                    service php-fpm stop >>$error_log 2>&1
                    service php-fpm start >>$error_log 2>&1
                    service httpd status >>$error_log 2>&1
                    service php-fpm status >>$error_log 2>&1
                    ;;
            esac
            ;;
    esac
    errorStat $?
    caCreated="yes"
}
configureHttpd() {
    dots "Stopping web service"
    case $systemctl in
        yes)
            case $osid in
                1|3)
                    systemctl is-active --quiet httpd php-fpm && systemctl stop httpd php-fpm >>$error_log 2>&1 || true
                    ;;
                2)
                    systemctl is-active --quiet apache2 php${php_ver}-fpm && systemctl stop apache2 php${php_ver}-fpm >>$error_log 2>&1 || true
                    ;;
            esac
            errorStat $?
            ;;
        *)
            case $osid in
                1)
                    service httpd stop >>$error_log 2>&1
                    service php-fpm stop >>$error_log 2>&1
                    errorStat $?
                    ;;
                2)
                    service apache2 stop >>$error_log 2>&1
                    service php${php_ver}-fpm stop >>$error_log 2>&1
                    errorStat $?
                    ;;
            esac
            ;;
    esac
    dots "Setting up Apache and PHP files"
    if [[ ! -f $phpini ]]; then
        echo "Failed"
        echo "   ###########################################"
        echo "   #                                         #"
        echo "   #      PHP Failed to install properly     #"
        echo "   #                                         #"
        echo "   ###########################################"
        echo
        echo "   Could not find $phpini!"
        exit 1
    fi
    if [[ $osid -eq 3 ]]; then
        if [[ ! -f $httpdconf ]]; then
            echo "   Apache configs not found!"
            exit 1
        fi
        # Enable Event
        sed -i '/LoadModule mpm_event_module modules\/mod_mpm_event.so/s/^#//g' $httpdconf >>$error_log 2>&1
        # Disable prefork and worker
        sed -i '/LoadModule mpm_prefork_module modules\/mod_mpm_prefork.so/s/^/#/g' $httpdconf >>$error_log 2>&1
        sed -i '/LoadModule mpm_worker_module modules\/mod_mpm_worker.so/s/^/#/g' $httpdconf >>$error_log 2>&1
        # Enable proxy
        sed -i '/LoadModule proxy_html_module modules\/mod_proxy_html.so/s/^#//g' $httpdconf >>$error_log 2>&1
        sed -i '/LoadModule xml2enc_module modules\/mod_xml2enc.so/s/^#//g' $httpdconf >>$error_log 2>&1
        sed -i '/LoadModule proxy_module modules\/mod_proxy.so/s/^#//g' $httpdconf >>$error_log 2>&1
        sed -i '/LoadModule proxy_http_module modules\/mod_proxy_http.so/s/^#//g' $httpdconf >>$error_log 2>&1
        sed -i '/LoadModule proxy_fcgi_module modules\/mod_proxy_fcgi.so/s/^#//g' $httpdconf >>$error_log 2>&1
        # Enable socache
        sed -i '/LoadModule socache_shmcb_module modules\/mod_socache_shmcb.so/s/^#//g' $httpdconf >>$error_log 2>&1
        # Enable ssl
        sed -i '/LoadModule ssl_module modules\/mod_ssl.so/s/^#//g' $httpdconf >>$error_log 2>&1
        # Enable rewrite
        sed -i '/LoadModule rewrite_module modules\/mod_rewrite.so/s/^#//g' $httpdconf >>$error_log 2>&1
        # Enable our virtual host file for fog
        grep -q "^Include conf/extra/fog\.conf" $httpdconf || echo -e "# FOG Virtual Host\nListen 443\nInclude conf/extra/fog.conf" >>$httpdconf
        # Enable php extensions
        sed -i 's/;extension=bcmath/extension=bcmath/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=curl/extension=curl/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=ftp/extension=ftp/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=gd/extension=gd/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=gettext/extension=gettext/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=ldap/extension=ldap/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=mysqli/extension=mysqli/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=openssl/extension=openssl/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=pdo_mysql/extension=pdo_mysql/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=posix/extension=posix/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=sockets/extension=sockets/g' $phpini >>$error_log 2>&1
        sed -i 's/;extension=zip/extension=zip/g' $phpini >>$error_log 2>&1
        sed -i 's/^open_basedir\ =/;open_basedir\ =/g' $phpini >>$error_log 2>&1
    fi
    sed -i 's/post_max_size\ \=\ 8M/post_max_size\ \=\ 3000M/g' $phpini >>$error_log 2>&1
    sed -i 's/upload_max_filesize\ \=\ 2M/upload_max_filesize\ \=\ 3000M/g' $phpini >>$error_log 2>&1
    sed -i 's/.*max_input_vars\ \=.*$/max_input_vars\ \=\ 250000/g' $phpini >>$error_log 2>&1
    errorStat $?
    dots "Testing and removing symbolic links if found"
    if [[ -h ${docroot}fog ]]; then
        rm -f ${docroot}fog >>$error_log 2>&1
    fi
    if [[ -h ${docroot}${webroot} ]]; then
        rm -f ${docroot}${webroot} >>$error_log 2>&1
    fi
    errorStat $?
    dots "Backing up old data"
    if [[ -d $backupPath/fog_web_${version}.BACKUP ]]; then
        rm -rf $backupPath/fog_web_${version}.BACKUP >>$error_log 2>&1
    fi
    if [[ -d $webdirdest ]]; then
        cp -RT "$webdirdest" "${backupPath}/fog_web_${version}.BACKUP" >>$error_log 2>&1
        rm -rf ${backupPath}/fog_web_${version}.BACKUP/lib/plugins/accesscontrol
        rm -rf "$webdirdest" >>$error_log 2>&1
    fi
    if [[ $osid -eq 2 ]]; then
        if [[ -d ${docroot}fog ]]; then
            rm -rf ${docroot} >>$error_log 2>&1
        fi
    fi
    mkdir -p "$webdirdest" >>$error_log 2>&1
    if [[ -d $docroot && ! -h ${docroot}fog ]] || [[ ! -d ${docroot}fog ]]; then
        ln -s $webdirdest  ${docroot}/fog >>$error_log 2>&1
    fi
    errorStat $?
    if [[ $copybackold -gt 0 ]]; then
        if [[ -d ${backupPath}/fog_web_${version}.BACKUP ]]; then
            dots "Copying back old web folder as is";
            cp -Rf ${backupPath}/fog_web_${version}.BACKUP/* $webdirdest/
            errorStat $?
            dots "Ensuring all classes are lowercased"
            for i in $(find $webdirdest -type f -name "*[A-Z]*\.class\.php" -o -name "*[A-Z]*\.event\.php" -o -name "*[A-Z]*\.hook\.php" 2>>$error_log); do
                mv "$i" "$(echo $i | tr A-Z a-z)" >>$error_log 2>&1
            done
            errorStat $?
        fi
    fi
    dots "Copying new files to web folder"
    cp -Rf $webdirsrc/* $webdirdest/
    errorStat $?
    for i in $(find $backupPath/fog_web_${version}.BACKUP/management/other/ -maxdepth 1 -type f -not -name gpl-3.0.txt -a -not -name index.php -a -not -name 'ca.*' 2>>$error_log); do
        cp -Rf $i ${webdirdest}/management/other/ >>$error_log 2>&1
    done
    if [[ $installlang -eq 1 ]]; then
        dots "Creating the language binaries"
        langpath="${webdirdest}/management/languages"
        languagesfound=$(find $langpath -maxdepth 1 -type d -exec basename {} \; | awk -F. '/\./ {print $1}' 2>>$error_log)
        languagemogen "$languagesfound" "$langpath"
        echo "Done"
    fi
    dots "Creating config file"
    phpescsnmysqlpass="${snmysqlpass//\\/\\\\}";   # Replace every \ with \\ ...
    phpescsnmysqlpass="${phpescsnmysqlpass//\'/\\\'}"   # and then every ' with \' for full PHP escaping
    echo "<?php
/**
 * The main configuration FOG uses.
 *
 * PHP Version 5
 *
 * Constructs the configuration we need to run FOG.
 *
 * @category Config
 * @package  FOGProject
 * @author   Tom Elliott <tommygunsster@gmail.com>
 * @license  http://opensource.org/licenses/gpl-3.0 GPLv3
 * @link     https://fogproject.org
 */
/**
 * The main configuration FOG uses.
 *
 * @category Config
 * @package  FOGProject
 * @author   Tom Elliott <tommygunsster@gmail.com>
 * @license  http://opensource.org/licenses/gpl-3.0 GPLv3
 * @link     https://fogproject.org
 */
class Config
{
    /**
     * Calls the required functions to define items
     *
     * @return void
     */
    public function __construct()
    {
        global \$node;
        self::_dbSettings();
        self::_svcSetting();
        if (\$node == 'schema') {
            self::_initSetting();
        }
    }
    /**
     * Defines the database settings for FOG
     *
     * @return void
     */
    private static function _dbSettings()
    {
        define('DATABASE_TYPE', 'mysql'); // mysql or oracle
        define('DATABASE_HOST', '$snmysqlhost');
        define('DATABASE_NAME', '$mysqldbname');
        define('DATABASE_USERNAME', '$snmysqluser');
        define('DATABASE_PASSWORD', '$phpescsnmysqlpass');
    }
    /**
     * Defines the service settings
     *
     * @return void
     */
    private static function _svcSetting()
    {
        define('UDPSENDERPATH', '/usr/local/sbin/udp-sender');
        define('MULTICASTINTERFACE', '${interface}');
        define('UDPSENDER_MAXWAIT', null);
    }
    /**
     * Initial values if fresh install are set here
     * NOTE: These values are only used on initial
     * installation to set the database values.
     * If this is an upgrade, they do not change
     * the values within the Database.
     * Please use FOG Configuration->FOG Settings
     * to change these values after everything is
     * setup.
     *
     * @return void
     */
    private static function _initSetting()
    {
        define('TFTP_HOST', \"${ipaddress}\");
        define('TFTP_FTP_USERNAME', \"${username}\");
        define('TFTP_FTP_PASSWORD', '${password}');
        define('TFTP_PXE_KERNEL_DIR', \"${webdirdest}/service/ipxe/\");
        define('PXE_KERNEL', 'bzImage');
        define('PXE_KERNEL_RAMDISK', 275000);
        define('USE_SLOPPY_NAME_LOOKUPS', true);
        define('MEMTEST_KERNEL', 'memtest.bin');
        define('PXE_IMAGE', 'init.xz');
        define('STORAGE_HOST', \"${ipaddress}\");
        define('STORAGE_FTP_USERNAME', \"${username}\");
        define('STORAGE_FTP_PASSWORD', '${password}');
        define('STORAGE_DATADIR', '${storageLocation}/');
        define('STORAGE_DATADIR_CAPTURE', '${storageLocationCapture}');
        define('STORAGE_BANDWIDTHPATH', '${webroot}status/bandwidth.php');
        define('STORAGE_INTERFACE', '${interface}');
        define('CAPTURERESIZEPCT', 7);
        define('WEB_HOST', \"${ipaddress}\");
        define('WOL_HOST', \"${ipaddress}\");
        define('WOL_PATH', '/${webroot}wol/wol.php');
        define('WOL_INTERFACE', \"${interface}\");
        define('SNAPINDIR', \"${snapindir}/\");
        define('QUEUESIZE', '10');
        define('CHECKIN_TIMEOUT', 600);
        define('USER_MINPASSLENGTH', 4);
        define('NFS_ETH_MONITOR', \"${interface}\");
        define('UDPCAST_INTERFACE', \"${interface}\");
        // Must be an even number! recommended between 49152 to 65535
        define('UDPCAST_STARTINGPORT', 63100);
        define('FOG_MULTICAST_MAX_SESSIONS', 64);
        define('FOG_JPGRAPH_VERSION', '2.3');
        define('FOG_REPORT_DIR', './reports/');
        define('FOG_CAPTUREIGNOREPAGEHIBER', true);
        define('FOG_THEME', 'default/fog.css');
    }
}" > "${webdirdest}/lib/fog/config.class.php"
    errorStat $?
    dots "Creating redirection index file"
    if [[ ! -f ${docroot}/index.php ]]; then
        echo "<?php
header('Location: /fog/index.php');
die();
?>" > ${docroot}/index.php && chown ${apacheuser}:${apacheuser} ${docroot}/index.php
        errorStat $?
    else
        echo "Skipped"
    fi
    downloadfiles
    if [[ $osid -eq 2 ]]; then
        php -m | grep mysqlnd >>$error_log 2>&1
        if [[ ! $? -eq 0 ]]; then
            phpenmod mysqlnd >>$error_log 2>&1
            if [[ ! $? -eq 0 ]]; then
                if [[ -e /etc/php${php_ver}/conf.d/mysqlnd.ini ]]; then
                    cp -f "/etc/php${php_ver}/conf.d/mysqlnd.ini" "/etc/php${php_ver}/mods-available/php${php_ver}-mysqlnd.ini" >>$error_log 2>&1
                    phpenmod mysqlnd >>$error_log 2>&1
                fi
            fi
        fi
    fi
    dots "Enabling apache and fpm services on boot"
    if [[ $osid -eq 2 ]]; then
        if [[ $systemctl == yes ]]; then
            systemctl is-enabled --quiet apache2 && true || systemctl enable apache2 >>$error_log 2>&1
            systemctl is-enabled --quiet $phpfpm && true || systemctl enable $phpfpm >>$error_log 2>&1
        else
            sysv-rc-conf apache2 on >>$error_log 2>&1
            sysv-rc-conf $phpfpm on >>$error_log 2>&1
        fi
    elif [[ $systemctl == yes ]]; then
        systemctl is-enabled --quiet httpd php-fpm && true || systemctl enable httpd php-fpm >>$error_log 2>&1
    else
        chkconfig php-fpm on >>$error_log 2>&1
        chkconfig httpd on >>$error_log 2>&1
    fi
    errorStat $?
    createSSLCA
    dots "Changing permissions on apache log files"
    chmod +rx $apachelogdir
    chmod +rx $apacheerrlog
    chmod +rx $apacheacclog
    chown -R ${apacheuser}:${apacheuser} $webdirdest
    touch $webdirdest/fog_login_accepted.log
    touch $webdirdest/fog_login_failed.log
    chown ${apacheuser}:${apacheuser} $webdirdest/fog_login_*.log
    chmod 0200 $webdirdest/fog_login_*.log
    errorStat $?
    [[ -d /var/www/html/ && ! -e /var/www/html/fog/ ]] && ln -s "$webdirdest" /var/www/html/
    [[ -d /var/www/ && ! -e /var/www/fog ]] && ln -s "$webdirdest" /var/www/
    chown -R ${apacheuser}:${apacheuser} "$webdirdest"
    chown -R ${username}:${apacheuser} "$webdirdest/service/ipxe"
}
downloadfiles() {
    local copypath=""
    dots "Downloading kernel, init and fog-client binaries"
    clientVer="$(awk -F\' /"define\('FOG_CLIENT_VERSION'[,](.*)"/'{print $4}' ../packages/web/lib/fog/system.class.php | tr -d '[[:space:]]')"
    fosURL="https://github.com/FOGProject/fos/releases/download"
    fosLatestURL="https://github.com/FOGProject/fos/releases/latest/download"
    fogclientURL="https://github.com/FOGProject/fog-client/releases/download"
    [[ ! -d ../tmp/  ]] && mkdir -p ../tmp/ >/dev/null 2>&1
    cwd=$(pwd)
    cd ../tmp/
    if [[ $version =~ ^[0-9]\.[0-9]\.[0-9]+$ ]]; then
        urls=( "${fosURL}/${version}/init.xz" "${fosURL}/${version}/init_32.xz" "${fosURL}/${version}/bzImage" "${fosURL}/${version}/bzImage32" "${fosURL}/${version}/arm_init.cpio.gz" "${fosURL}/${version}/arm_Image" "${fogclientURL}/${clientVer}/FOGService.msi" "${fogclientURL}/${clientVer}/SmartInstaller.exe" )
    else
        urls=( "${fosLatestURL}/init.xz" "${fosLatestURL}/init_32.xz" "${fosLatestURL}/bzImage" "${fosLatestURL}/bzImage32" "${fosLatestURL}/arm_init.cpio.gz" "${fosLatestURL}/arm_Image" "${fogclientURL}/${clientVer}/FOGService.msi" "${fogclientURL}/${clientVer}/SmartInstaller.exe" )
    fi
    for url in "${urls[@]}"; do
        checksum=1
        cnt=0
        filename=$(basename -- "$url")
        hashfile="${filename}.sha256"
        baseurl=$(dirname -- "$url")
        hashurl="${baseurl}/${hashfile}"
        # make sure we download the most recent hash file to start with
        if [[ -f $hashfile ]]; then
            rm -f $hashfile
            curl --silent -kOL $hashurl >>$error_log 2>&1
        fi
        while [[ $checksum -ne 0 && $cnt -lt 10 ]]; do
            [[ -f $hashfile ]] && sha256sum --check $hashfile >>$error_log 2>&1
            checksum=$?
            if [[ $checksum -ne 0 ]]; then
                curl --silent -kOL $url >>$error_log
                curl --silent -kOL $hashurl >>$error_log
            fi
            let cnt+=1
        done
        if [[ $checksum -ne 0 ]]; then
            echo " * Could not download $filename properly"
            [[ -z $exitFail ]] && exit 1
        fi
    done
    echo "Done"
    dots "Copying binaries to destination paths"
    cp -vf ${copypath}bzImage ${webdirdest}/service/ipxe/ >>$error_log 2>&1 || errorStat $?
    cp -vf ${copypath}bzImage32 ${webdirdest}/service/ipxe/ >>$error_log 2>&1 || errorStat $?
    cp -vf ${copypath}init.xz ${webdirdest}/service/ipxe/ >>$error_log 2>&1 || errorStat $?
    cp -vf ${copypath}init_32.xz ${webdirdest}/service/ipxe/ >>$error_log 2>&1 || errorStat $?
    cp -vf ${copypath_arm}arm_Image ${webdirdest}/service/ipxe/ >>$error_log 2>&1 || errorStat $?
    cp -vf ${copypath_arm}arm_init.cpio.gz ${webdirdest}/service/ipxe/ >>$error_log 2>&1 || errorStat $?
    cp -vf ${copypath}FOGService.msi ${copypath}SmartInstaller.exe ${webdirdest}/client/ >>$error_log 2>&1
    errorStat $?
    cd $cwd
}
configureDHCP() {
    case $linuxReleaseName_lower in
        *debian*)
            if [[ $bldhcp -eq 1 ]]; then
                dots "Setting up and starting DHCP Server (incl. fix for Debian)"
                sed -i.fog "s/INTERFACESv4=\"\"/INTERFACESv4=\"$interface\"/g" /etc/default/isc-dhcp-server
            else
                dots "Setting up and starting DHCP Server"
            fi
            ;;
        *)
            dots "Setting up and starting DHCP Server"
            ;;
    esac
    case $bldhcp in
        1)
            serverip=$(ip -4 -o addr show $interface | awk -F'([ /])+' '/global/ {print $4}')
            [[ -z $serverip ]] && serverip=$(/sbin/ifconfig $interface | grep -oE 'inet[:]? addr[:]?([0-9]{1,3}\.){3}[0-9]{1,3}' | awk -F'(inet[:]? ?addr[:]?)' '{print $2}')
            [[ -z $submask ]] && submask=$(cidr2mask $(getCidr $interface))
            network=$(mask2network $serverip $submask)
            [[ -z $startrange ]] && startrange=$(addToAddress $network 10)
            [[ -z $endrange ]] && endrange=$(subtract1fromAddress $(echo $(interface2broadcast $interface)))
            [[ -f $dhcpconfig ]] && dhcptouse=$dhcpconfig
            [[ -f $dhcpconfigother ]] && dhcptouse=$dhcpconfigother
            if [[ -z $dhcptouse || ! -f $dhcptouse ]]; then
                echo "Failed"
                echo "Could not find dhcp config file"
                exit 1
            fi
            mv -fv "${dhcptouse}" "${dhcptouse}.${timestamp}" >>$error_log 2>&1
            echo "# DHCP Server Configuration file\n#see /usr/share/doc/dhcp*/dhcpd.conf.sample" > $dhcptouse
            echo "# This file was created by FOG" >> "$dhcptouse"
            echo "#Definition of PXE-specific options" >> "$dhcptouse"
            echo "# Code 1: Multicast IP Address of bootfile" >> "$dhcptouse"
            echo "# Code 2: UDP Port that client should monitor for MTFTP Responses" >> "$dhcptouse"
            echo "# Code 3: UDP Port that MTFTP servers are using to listen for MTFTP requests" >> "$dhcptouse"
            echo "# Code 4: Number of seconds a client must listen for activity before trying" >> "$dhcptouse"
            echo "#         to start a new MTFTP transfer" >> "$dhcptouse"
            echo "# Code 5: Number of seconds a client must listen before trying to restart" >> "$dhcptouse"
            echo "#         a MTFTP transfer" >> "$dhcptouse"
            echo "option space PXE;" >> "$dhcptouse"
            echo "option PXE.mtftp-ip code 1 = ip-address;" >> "$dhcptouse"
            echo "option PXE.mtftp-cport code 2 = unsigned integer 16;" >> "$dhcptouse"
            echo "option PXE.mtftp-sport code 3 = unsigned integer 16;" >> "$dhcptouse"
            echo "option PXE.mtftp-tmout code 4 = unsigned integer 8;" >> "$dhcptouse"
            echo "option PXE.mtftp-delay code 5 = unsigned integer 8;" >> "$dhcptouse"
            echo "option arch code 93 = unsigned integer 16;" >> "$dhcptouse"
            echo "use-host-decl-names on;" >> "$dhcptouse"
            echo "ddns-update-style interim;" >> "$dhcptouse"
            echo "ignore client-updates;" >> "$dhcptouse"
            echo "# Specify subnet of ether device you do NOT want service." >> "$dhcptouse"
            echo "# For systems with two or more ethernet devices." >> "$dhcptouse"
            echo "# subnet 136.165.0.0 netmask 255.255.0.0 {}" >> "$dhcptouse"
            echo "subnet $network netmask $submask{" >> "$dhcptouse"
            echo "    option subnet-mask $submask;" >> "$dhcptouse"
            echo "    range dynamic-bootp $startrange $endrange;" >> "$dhcptouse"
            echo "    default-lease-time 21600;" >> "$dhcptouse"
            echo "    max-lease-time 43200;" >> "$dhcptouse"
            [[ ! $(validip $routeraddress) -eq 0 ]] && routeraddress=$(echo $routeraddress | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
            [[ ! $(validip $dnsaddress) -eq 0 ]] && dnsaddress=$(echo $dnsaddress | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
            [[ $(validip $routeraddress) -eq 0 ]] && echo "    option routers $routeraddress;" >> "$dhcptouse" || echo "    #option routers 0.0.0.0" >> "$dhcptouse"
            [[ $(validip $dnsaddress) -eq 0 ]] && echo "    option domain-name-servers $dnsaddress;" >> "$dhcptouse" || echo "    #option domain-name-servers 0.0.0.0" >> "$dhcptouse"
            echo "    next-server $ipaddress;" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"Legacy\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00000\";" >> "$dhcptouse"
            echo "    filename \"undionly.kkpxe\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"UEFI-32-2\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00002\";" >> "$dhcptouse"
            echo "    filename \"i386-efi/snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"UEFI-32-1\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00006\";" >> "$dhcptouse"
            echo "    filename \"i386-efi/snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"UEFI-64-1\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00007\";" >> "$dhcptouse"
            echo "    filename \"snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"UEFI-64-2\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00008\";" >> "$dhcptouse"
            echo "    filename \"snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"UEFI-64-3\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00009\";" >> "$dhcptouse"
            echo "    filename \"snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"UEFI-ARM64\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 20) = \"PXEClient:Arch:00011\";" >> "$dhcptouse"
            echo "    filename \"arm64-efi/snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"SURFACE-PRO-4\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 32) = \"PXEClient:Arch:00007:UNDI:003016\";" >> "$dhcptouse"
            echo "    filename \"snponly.efi\";" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            echo "class \"Apple-Intel-Netboot\" {" >> "$dhcptouse"
            echo "    match if substring(option vendor-class-identifier, 0, 14) = \"AAPLBSDPC/i386\";" >> "$dhcptouse"
            echo "    option dhcp-parameter-request-list 1,3,17,43,60;" >> "$dhcptouse"
            echo "    if (option dhcp-message-type = 8) {" >> "$dhcptouse"
            echo "        option vendor-class-identifier \"AAPLBSDPC\";" >> "$dhcptouse"
            echo "        if (substring(option vendor-encapsulated-options, 0, 3) = 01:01:01) {" >> "$dhcptouse"
            echo "            # BSDP List" >> "$dhcptouse"
            echo "            option vendor-encapsulated-options 01:01:01:04:02:80:00:07:04:81:00:05:2a:09:0D:81:00:05:2a:08:69:50:58:45:2d:46:4f:47;" >> "$dhcptouse"
            echo "            filename \"snponly.efi\";" >> "$dhcptouse"
            echo "        }" >> "$dhcptouse"
            echo "    }" >> "$dhcptouse"
            echo "}" >> "$dhcptouse"
            diffconfig "${dhcptouse}"
            case $systemctl in
                yes)
                    systemctl is-enabled --quiet $dhcpd && true || systemctl enable $dhcpd >>$error_log 2>&1
                    systemctl is-active --quiet $dhcpd && systemctl stop $dhcpd >>$error_log 2>&1 || false
                    systemctl is-active --quiet $dhcpd && true || systemctl start $dhcpd >>$error_log 2>&1
                    systemctl status $dhcpd >>$error_log 2>&1
                    ;;
                *)
                    case $osid in
                        1)
                            chkconfig $dhcpd on >>$error_log 2>&1
                            service $dhcpd stop >>$error_log 2>&1
                            service $dhcpd start >>$error_log 2>&1
                            service $dhcpd status >>$error_log 2>&1
                            ;;
                        2)
                            sysv-rc-conf $dhcpd on >>$error_log 2>&1
                            /etc/init.d/$dhcpd stop >>$error_log 2>&1
                            /etc/init.d/$dhcpd start >>$error_log 2>&1
                            ;;
                    esac
                    ;;
            esac
            errorStat $?
            ;;
        *)
            echo "Skipped"
            ;;
    esac
}
vercomp() {
    [[ $1 == $2 ]] && return 0
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]} ]] && ver2[i]=0
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    return 0
}
languagemogen() {
    local languages="$1"
    local langpath="$2"
    local IFS=$'\n'
    local lang=''
    for lang in ${languages[@]}; do
        [[ ! -d "${langpath}/${lang}.UTF-8" ]] && continue
        msgfmt -o \
            "${langpath}/${lang}.UTF-8/LC_MESSAGES/messages.mo" \
            "${langpath}/${lang}.UTF-8/LC_MESSAGES/messages.po" \
            >>$error_log 2>&1
    done
}
generatePassword() {
    local length="$1"
    [[ $length -ge 12 && $length -le 128 ]] || length=20

    while [[ ${#genpassword} -lt $((length-1)) || -z $special ]]; do
        newchar=$(head -c1 /dev/urandom | tr -dc '0-9a-zA-Z!#$%&()*+,-./:;<=>?@[]^_{|}~')
        if [[ -n $(echo $newchar | tr -dc '!#$%&()*+,-./:;<=>?@[]^_{|}~') ]]; then
            special=${newchar}
        elif [[ ${#genpassword} -lt $((length-1)) ]]; then
            genpassword=${genpassword}${newchar}
        fi
    done
    # 9$(date +%N) seems weird but it's important because date may return
    # a leading 0 causing modulo to fail on reading it as octal number
    position=$(( 9$(date +%N) % $length ))
    # inject the special character at a random position
    echo ${genpassword::($position)}$special${genpassword:($position)}
}
checkPasswordChars() {
    checkpass="$(echo "$1" | tr -d '0-9a-zA-Z!#$%&()*+,-./:;<=>?@[]^_{|}~')"
    if [[ -n "$checkpass" ]]; then
        echo "Failed"
        echo ""
        echo "# The fog system account password includes characters we cannot properly"
        echo "# handle. Please remove the following character(s) in line password= of"
        echo "# your .fogsettings file before re-running the installer: $checkpass"
        echo ""
        exit 1
    fi
}
diffconfig() {
    local conffile="$1"
    [[ ! -f "${conffile}.${timestamp}" ]] && return 0
    diff -q "${conffile}" "${conffile}.${timestamp}" >>$error_log 2>&1
    if [[ $? -eq 0 ]]; then
        rm -f "${conffile}.${timestamp}" >>$error_log 2>&1
    else
        backupconfig="${backupconfig} ${conffile}"
    fi
}
setupFogReporting() {
    [[ $sendreports == "N" ]] && return
    local rreports="/opt/fog/reporting/report.sh"
    dots "Setting up FOG External Reporting"
    # Make sure required directories exist
    mkdir -p /opt/fog/reporting >>$error_log 2>&1
    mkdir -p /var/log/fog >>$error_log 2>&1
    # If the report settings file does not exist, create it.
    if [[ ! -f /opt/fog/reporting/settings ]]; then
        /usr/bin/awk -f $workingdir/../utils/reporting/reportingcronrandom.awk >> /opt/fog/reporting/settings
    fi
    # Pull in our reporting settings
    source /opt/fog/reporting/settings >>$error_log 2>&1

    crondfile="/etc/cron.d/fog_reporting"
    mv -fv "${crondfile}" "${crondfile}.${timestamp}" >>$error_log 2>&1
    # Build the cron.d file
    cat > ${crondfile} <<END_OF_REPORTING_FILE
SHELL=/bin/bash
PATH=${PATH}
${minute_of_hour} ${hour_of_day} * * ${day_of_week} ${user_to_run_as} ${rreports} >> ${reporting_log} 2>&1
END_OF_REPORTING_FILE
    diffconfig "${crondfile}"
    # If the reporting script exists, create a backup of it.
    mv -fv "${rreports}" "${rreports}.${timestamp}" >>$error_log 2>&1
    # Copy the new reporting script
    cp $workingdir/../utils/reporting/report.sh ${rreports} >>$error_log 2>&1
    # List change into backupconfig variable
    diffconfig "${rreports}"
    chmod +x ${rreports} >>$error_log 2>&1
    echo "Done"
}
