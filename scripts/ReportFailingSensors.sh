#!/bin/bash
# Check MySense measurements database on misfunctioning sensors

# Contact Teus Hagen webmaster@behouddeparel.nl to report improvements and bugs
#
# Copyright (C) 2020, Behoud de Parel, Teus Hagen, the Netherlands
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# $Id: ReportFailingSensors.sh,v 1.31 2020/10/25 10:01:34 teus Exp teus $

CMD="$(basename $0) $(echo '$Revision: 1.31 $' | sed -e 's/\$//g' -e 's/ision://')"
if [ "${1/*-h*/help}" == help ]
then
    echo "
Environment variables supported:
MySQL credentials: DBUSER=$USER, DBPASS=interact, DBHOST=localhost, DB=luchtmetingen
Default period to check fir sensor failures: START='3 weeks ago', LAST=now
Regions or project names: REGION='.*' regular expression
Sensors to check for eg SENSORS='temp rv pm10 pm1', dflt: SENSORS='(temp|rv)'
Arguments: kits to be searched for. No argument: all kits from the REGION
Example of command:
check kit SAN_1234567abc and all active kits of project HadM
    DBUSER=$USER DBHOST=localhost DBPASS=acacadabra DB=luchtmetingen $0 SAN_1234567abc HadM
check all kits active of projects SAN and HadM
    DBUSER=$USER DBHOST=localhost DBPASS=acacadabra DB=luchtmetingen REGION='(SAN|HadM)' $0
If command is used from terminal the output info will be colered.
Date/time in period may have format understood by the 'date' command.
Environment vars:
    DBUSER ($USER),DBPASS (acacadabra),DB (luchtmetingen),DBHOST (localhost),
    VERBOSE (verbosity dflt 0),START and END period,REGION (expresion, all),
    SENSORS (expression, sensor values to test for),
    LOWER (minimal static value count)
    "
    exit 0
fi

# MySQL database credentials
# will use here mysql --login-path=luchtmetingen as well!
DEBUG=${DEBUG}
export DB=${DB:-luchtmetingen}
export DBUSER=${DBUSER:-$USER}
export DBHOST=${DBHOST:-localhost}
if [ -z "$DBPASS" ]
then
    read -p "Provide password for database $DB on host $DBHOST user $DBUSER: " DBPASS
fi
export DBPASS=${DBPASS:-accacadabra}
# how to approach MySQL database. Uses mysql DB configuration in home user
# needs ~/.my.cnf
MYSQL="mysql --login-path=${DB:-luchtmetingen} -h ${DBHOST:-localhost} -N -B --silent ${DB:-luchtmetingen}"

SENSORS=${SENSORS:-'(temp|rv)'}  # sensors to check for static values

# sensors to check if there is data for them
METEO='(temp|rv|luchtdruk)'           # meteo type of sensors
DUSTCNT='(pm10_cnt|pm25_cnt|pm1_cnt)' # dust count type of sensors
DUST='(pm10|pm25|pm1)'                # dust mass type of sensors

VERBOSE=${VERBOSE:-0}
if [ -n "$DEBUG" ] ; then VERBOSE=3 ; fi
LOCATION=''     # will get KIT serial and location on error
LOWER=${LOWER:-5}  # default static value count to decide its static
declare -A EXCLUDES
# exceptions when static value is natural
EXCLUDES[luchtdruk]=15

# REGIONs: BdP (HadM), GLV (Venray), RIVM, ...
if [ -z "$REGION" ] && [ -z "$1" ]
then
    if [ -z "$1" ]
    then
        read -p 'Choose region to check for valid values of sensor: ' REGION
    fi
    REGION="${REGION:-.*}"  # use REGION to be prepended to generated HTML file name
fi

# period up to dflt now
if [ -z "$LAST" ] || ! date --date="$LAST" >/dev/null # last date to show in graphs
then
  LAST=now       # use measurement data up to $LAST
fi
LAST=$(date --date="$LAST" "+%Y/%m/%d %H:%M:00")
# start period from dflt 3 weeks ago
if [ -n "$START" ] && date --date=$START
then
    START="$(date --date='$START' '+%Y/%m/%d %H:%M')"
else
    START="$(date --date='3 weeks ago' '+%Y/%m/%d %H:%M')" # only last 3 weeks from now
fi

if [ -t 2 ] # color terminal output
then
    RED="\033[1;31m"
    GREEN="\033[1;32m"
    NOCOLOR="\033[0m"
else
    RED=""
    GREEN=""
    NOCOLOR=''
fi

# human readable date/time in std format no seconds
function DATE() {
    date --date=@"${1:-$(date '+%s')}" '+%Y-%m-%d %H:%M'
    return $?
}

# convert date/time to seconds from UNIX epoch
function Date2Secs() {
    if echo "$1" | grep -P -q '^[0-9]+$'
    then echo "$1"
    else echo $(date --date="${1:-now}" "+%s")
    fi
    return $?
}

# if present use attendation email events as last sending date
declare -A ATTENT
if [ -s ~/.ATTENTS.sh ]
then
    grep -P '^ATTENT\[[A-Za-z]+_[A-Fa-f0-9]+@[a-zA-Z]+[a-zA-Z0-9]*\]=' ~/.ATTENTS.sh >/var/tmp/Check$$
    if [ -s /var/tmp/Check$$ ] ; then . /var/tmp/Check$$ ; fi
    rm -f /var/tmp/Check$$
fi
        
function GetLblLocation() {
    local KIT="$1" LOC
    if ! echo "$KIT" | grep -q -P '^[a-zA-Z]+_[0-9a-fA-F]+$'
    then
        # echo "Cannot obtail location for $KIT"
        return
    fi
    LOC=$($MYSQL -e "SELECT concat('Label: ',if(isnull(label),'unknown',label), '. Location: ',if(isnull(street),'street unknown',street), ', ', if(isnull(village),'unknown village',village),'.') FROM Sensors WHERE active AND project = '${KIT/_*/}' AND serial = '${KIT/*_/}' LIMIT 1")
    echo "${LOC/NULL/}"
    return
}

# email a notice on failure
function SendNotice() {
    local KIT=$1 SENS=$2 FILE=$3
    local NOTICE
    if [ ! -s $FILE ] ; then return 0 ; fi
    if [ -n "$DEBUG" ] || (( $VERBOSE > 1 ))
    then
        cat $FILE 1>&2
    fi
    if [ -z "${ATTENT[${KIT}@${SENS}]}" ] || (( $(date +%s) > (${ATTENT[${KIT}@${SENS}]} + 3*24*60*60) ))
    then
        ATTENT[${KIT}@${SENS}]=$(date +%s)
        NOTICE=$($MYSQL -e "SELECT notice FROM Sensors WHERE active AND NOT isnull(notice) AND project = '${KIT/_*/}' AND serial = '${KIT/*_/}' LIMIT 1")
        NOTICE=$(echo "$NOTICE" | sed -e 's/,* *slack:[^,]*//' -e 's/email: *//g' -e 's/^  *//' -e 's/  *$//')
    elif (( $VERBOSE > 0 ))
    then
        echo SendNotices skipped upto $(DATE $((${ATTENT[${KIT}@${SENS}]} + 3*24*60*60)) ) 1>&2
        return 0
    fi
    if [ -n "$DEBUG" ] && [ -n "$NOTICE" ]
    then
        echo "$CMD: DEBUG: would send email notice to '$NOTICE'" 1>&2
        NOTICE=''
    fi
    if [ -n "${NOTICE}" ]
    then
        if [ -z "$LOCATION" ] ; then LOCATION=$(GetLblLocation "$KIT") ; fi
        if ! (echo "${LOCATION:-no location details for kit ${KIT} defined.}" ; cat $FILE ) | mail -r mysense@behouddeparel.nl -s "ATTENT: MySense kit $KIT sensor $SENS ${LOCATION:-Location is not defined.}" "$NOTICE"
        then
            echo -e "$CMD: ERROR sending email to $NOTICE with message:\n" "-----------------" 1>&2
            echo "${LOCATION:-no location details for kit ${KIT} known}"
            cat $FILE
        fi
    fi
    return $?
}

# de activate measurment kits from data acquisition
function InActivate() {
    for KIT in $@
    do
        $MYSQL -e "UPDATE Sensors SET active = 0 WHERE project = '${KIT/_*/}' AND serial = '${KIT/*_/}' AND active; UPDATE TTNtable SET active = 0, luftdaten = 0 WHERE project = '${KIT/_*/}' AND serial = '$
{KIT/*_/}' AND (active OR luftdaten);"
        echo "MySense kit $KIT has been deactivated for MySense measurements database and Luftdaten and other data portals forwarding." 1>&2
    done
    return $?
}

# check for enoug valid measurements in a period of time
# find null values for a TPE sensor as well static values over an amount of time
# deactivate kits not active in 6 months of time and send notice
function NrValids() {
    local KT="$1" TPE="$2" STRT=$(Date2Secs "$3") LST=$(Date2Secs "$4") DAT RTS=0
    declare -a STAT
    declare -i CNT
    CNT=$($MYSQL -e "SELECT count($TPE) FROM $KT WHERE not isnull($TPE)")
    if (( $CNT == 0 ))
    then
        echo "MySense kit $KT: has no active sensor $TPE on board." 1>&2
        return 0
    fi
    # STAT[0] count NULL values, STAT[1] count all measurements,
    # STAT[2]/STAT[3] min/max date/time
    STAT=($($MYSQL -e "SELECT count(*) FROM $KT WHERE isnull($TPE) AND UNIX_TIMESTAMP(datum) >= $STRT AND UNIX_TIMESTAMP(datum) <= $LST; SELECT count(*), UNIX_TIMESTAMP(min(datum)), UNIX_TIMESTAMP(max(datum)) FROM $KT WHERE UNIX_TIMESTAMP(datum) >= $STRT AND UNIX_TIMESTAMP(datum) <= $LST;") )
    if (( (${STAT[1]} - ${STAT[0]}) < 15 ))
    then  # not enough measurements in this period
        if (( $VERBOSE > 0 ))
        then
            if (( ${STAT[1]} > 0 ))
            then STAT[1]=$(( (${STAT[0]} * 100) / ${STAT[1]} ))
            else STAT[1]=0 ; fi
            echo "MySense kit $KT: not enough measurements (${STAT[1]} with ${STAT[0]} NULL values) ${STAT[1]}% in period of $(DATE ${STRT}) up to $(DATE ${LST})" 1>&2
            STAT[2]=$($MYSQL -e "SELECT UNIX_TIMESTAMP(datum) FROM $KT WHERE NOT isnull($TPE) ORDER BY datum DESC LIMIT 1")
            echo -e "\tLast active date $(DATE ${STAT[2]}) of sensor $TPE." 1>&2
            if (( ${STAT[2]} < $(date --date='6 months ago' +%s) ))
            then
                echo -e "Kit $KT was not active during last 6 months.\n" 1>&2
                InActivate $KT 1>&2
            fi
        fi
        # return nr of invalids, valids, first valued, last valued
        return 1
    fi
    declare -a VAL
    # see if a value looks like a static value in this period
    # get array of: different not NULL values, max date, a possible static value
    declare -i NEXT=$((${LST}-1))
    declare -i STATICS=0 NULLS=${STAT[0]} PERIODS=1 LAST_VALID=0
    local AVOID=10000
    while true   # try to find period(s) with static measurements
    do
        # NEXT last date/time this period of current loop, STAT[2] first date/time loop
        # current loop period: STAT[2] up to NEXT
        if (( ($NEXT - ${STAT[2]}) < 15 )) ; then break ; fi

        # VAL[0] static value, VAL[1] last date/time static value, VAL[2] count static value
        VAL=($($MYSQL -e "SELECT $TPE, UNIX_TIMESTAMP(max(datum)), count(*) AS cnt FROM $KT WHERE UNIX_TIMESTAMP(datum) >= ${STAT[2]} AND UNIX_TIMESTAMP(datum) < $NEXT AND NOT isnull($TPE) GROUP BY $TPE HAVING cnt > ${EXCLUDES[${TPE}]:-${LOWER}} ORDER BY cnt DESC LIMIT 1") )
        if [ -z "${VAL[2]}" ]
        then
            break
        elif (( ( (${VAL[2]}*100)/(${STAT[1]}-${STAT[0]}) ) <= 10 )) # more as 10% are static values
        then
            break
        fi
        if (( $LAST_VALID <= 0 )) # last value not null and not maybe static value
        then
            LAST_VALID=$($MYSQL -e "SELECT UNIX_TIMESTAMP(datum) FROM $KT WHERE UNIX_TIMESTAMP(datum) >= ${STAT[2]} AND UNIX_TIMESTAMP(datum) < $NEXT AND NOT isnull($TPE) AND $TPE != ${VAL[0]} ORDER BY datum DESC LIMIT 1")
        fi

        # NEXT date/time with a value not NULL and not maybe static
        NEXT=$($MYSQL -e "SELECT UNIX_TIMESTAMP(datum) FROM $KT WHERE NOT isnull($TPE) AND $TPE != ${VAL[0]} AND UNIX_TIMESTAMP(datum) < ${VAL[1]} AND UNIX_TIMESTAMP(datum) >= $STRT ORDER BY datum DESC LIMIT 1")
        if [ $NEXT = 0 ] ; then NEXT=${STAT[2]} ; fi # use first one

        # check if maybe static value was probably normal
        CNT=$($MYSQL -e "SELECT count(*) FROM $KT WHERE NOT isnull($TPE) AND $TPE = ${VAL[0]} AND UNIX_TIMESTAMP(datum) <= ${VAL[1]} AND UNIX_TIMESTAMP(datum) > $NEXT")
        if (( $CNT < 3 )) ; then continue ; fi

        if [ $AVOID = 10000 ] ; then AVOID=${VAL[0]} ; fi # first should be it
        STAT[0]=$(( ${STAT[0]} - $CNT)) ; STATICS+=$CNT ; PERIODS+=1
        if (( ${VAL[1]} > $LAST_VALID )) ; then RTS=1 ; fi # static period was old
        echo "MySense kit $KT: $CNT of ${STAT[1]} static (${VAL[0]} not NULL) measurements in period $(DATE ${NEXT}) up to $(DATE ${VAL[1]})" 1>&2
        # continue loop, find next static period
    done
    echo "MySense kit $KT: $((${STAT[1]}-${STAT[0]})) of ${STAT[1]} valid measurements $(( ( (${STAT[1]}-${STAT[0]})*100) / ${STAT[1]} ))% in period $(DATE ${STAT[2]}) up to $(DATE ${STAT[3]})" 1>&2
    echo -e "\tMeasurements sensor $TPE:\n\tTotal ${STAT[1]}, null valued: $NULLS, static valued: $STATICS, and $((${STAT[1]} - $NULLS - $STATICS)) valid valued in $PERIODS period(s)." 1>&2
    STAT[2]=$($MYSQL -e "SELECT UNIX_TIMESTAMP(datum) FROM $KT WHERE NOT isnull($TPE) AND $TPE != $AVOID ORDER BY datum DESC LIMIT 1")
    echo -e "\tLast active date $(DATE ${STAT[2]}) of sensor $TPE." 1>&2
    if (( (${STAT[2]} - $LST) > 2*60*60 )) ; then rts=1 ; fi
    return $RTS
}

# check if kit is producing measurmeent data in a period
# returns true/false and last date/time any sensed
function LastMeasurement() {
    local AKIT="$1" STRT="$2" LST="$3"
    local COLS COL SENSED DUST_E="$DUSTCNT"
    declare -i DT
    declare -i RECENT=$(date --date="$STRT" '+%s') STRTi
    STRTi=$RECENT
    if $MYSQL -e "SELECT description FROM Sensors WHERE project = '${AKIT/_*/}' AND serial = '${AKIT/*_/}' AND active ORDER BY datum DESC" | grep -q -P '(SDS011)' 
    then
        DUST_E="$DUST"
    fi
    COLS=$($MYSQL -e "DESCRIBE $AKIT" | awk '{ print $1; }' | grep -P "^(${DUST_E:-XYZ}|${METEO:-XxX})$")
    for COL in $COLS
    do
        DT=$($MYSQL -e "SELECT UNIX_TIMESTAMP(datum) FROM $AKIT WHERE datum >= '$STRT' AND datum <= '$LST' AND NOT ISNULL($COL) ORDER BY datum DESC LIMIT 1")
        if (( $DT > $RECENT ))
        then
            RECENT="$DT" ; SENSED="$COL"
        fi
    done
    if (( $RECENT == $STRTi  )) ; then echo -e "${RED}No recent meteo or dust measurement of any sensor${NOCOLOR} after date $STRT" ; return 1 ; fi
    if (( $VERBOSE == 0 )) ; then return 0 ; fi
    echo "Recent e.g. $SENSED measurement at date: "
    date --date="@$RECENT" "+%Y/%m/%d %H:%M"
    return 0
}

# check kit for silent sensors in a period of time
ActiveSenses=()
NotActiveSenses=()
NotOperational=()
function CheckSensors() {
    local AKIT="$1" STRT="$2" LST="$3"
    local COLS COL QRY='' DUST_E="$DUSTCNT"
    ActiveSenses=()
    NotActiveSenses=()
    NotOperational=()
    # some dust sensors do not have bin count
    if $MYSQL -e "SELECT description FROM Sensors WHERE project = '${AKIT/_*/}' AND serial
 = '${AKIT/*_/}' AND active ORDER BY datum DESC" | grep -q -P '(SDS011)' 
    then
        DUST_E="$DUST"
    fi
    COLS=$($MYSQL -e "DESCRIBE $AKIT" | awk '{ print $1; }' | grep -P "^(${DUST_E:-XYZ}|${METEO:-XxX})$")
    if [ -z "$COLS" ] ; then return 2 ; fi
    for COL in $COLS
    do
        if [ -n "$QRY" ] ; then QRY+=',' ; fi
        QRY+="(SELECT UNIX_TIMESTAMP(max(datum)) FROM $AKIT WHERE NOT ISNULL($COL) AND datum >= '$STRT' AND datum <= '$LST')"
    done
    declare -a DTS
    declare -i I=0
    declare -i LSTi=$(date --date="$LST" '+%s')
    DTS=($($MYSQL -e "SELECT $QRY"))
    local MSG=''
    declare -i NullCnt=0
    for COL in $COLS
    do
        if [ "${DTS[$I]}" = NULL ]
        then # set device not operational if no measurement in last 3 months of period
            NullCnt+=1
            if (( $($MYSQL -e "SELECT COUNT($COL) FROM $AKIT WHERE NOT ISNULL($COL) AND UNIX_TIMESTAMP(datum) >= ($LSTi-60*60*24*92) AND datum <= '$LST'") > 0 ))
            then
                MSG+="\tSensor $COL: no values in this period\n"
                NotActiveSenses[${#NotActiveSenses[@]}]="$COL"
            else
              NotOperational[${#NotOperational[@]}]="$COL"
              if (( $VERBOSE > 0 ))
              then
                echo "Sensor $COL in MySense kit $AKIT is not configured" 1>&2
                if (( $VERBOSE > 1 ))
                then
                    QRY=$($MYSQL -e "SELECT max(datum) FROM $AKIT WHERE NOT ISNULL($COL) AND UNIX_TIMESTAMP(datum) >= ($LSTi-60*60*24*92) AND datum <= '$LST'")
                    QRY=${QRY/*NULL*/3 months before end of period}
                    echo "Most recent measurement for $COL at date: $QRY" 1>&2
                fi
              fi
            fi
        elif (( "${DTS[$I]}" <= ($LSTi - 4*60*60) )) # alarm after N hours silence
        then
            MSG+="\tSensor $COL: last seen $(date --date=@${DTS[$I]} '+%Y/%m/%d %H:%M')\n"
            NotActiveSenses[${#NotActiveSenses[@]}]="$COL"
        else
            ActiveSenses[${#ActiveSenses[@]}]="$COL"
        fi
        I+=1
    done
    if (( ${#DTS[@]} == $NullCnt ))
    then
        echo -e "${RED}FAILURE: kit $AKIT is set as active but is silent in period $STRT up to $LST!${NOCOLOR}" 1>&2
    elif (( ${#NotActiveSenses[@]} > 0 ))
    then
        echo "${#NotActiveSenses[@]} of ${#DTS[@]} sensors less functioning in kit $AKIT in period $STRT up to $LST:" 1>&2
        echo -e "$MSG" 1>&2
    else
        return 0
    fi
    return 1
}

#CheckSensors SAN_b4e62df48fe9 "$(date --date='3 weeks ago' '+%Y/%m/%d %H:%M')" "$(date '+%Y/%m/%d %H:%M')"

# gert all kit table names for kits or region
function GetRegionalKits() {
    local RGN KIT KITS='' TBLS REGEXP MATCH
    TBLS=$($MYSQL -e 'SHOW TABLES' | grep -P '^[A-Za-z]+_[a-zA-Z0-9]{7,}$')
    for RGN in $@
    do
        MATCH=
        if echo "$RGN" | grep -q -P '_[a-fA-F0-9]+$'  # argument is a measurement kit
        then
            KITS+=" $RGN"
            continue
        fi
        if echo "$RGN" | grep -q -P '_.+'           # argument is pattern of measurement kit
        then
            if [ -n "${RGN/_*/}" ] ; then MATCH="project = '${RGN/_*/}' AND " ; fi
            RGN=$($MYSQL -e "SELECT DISTINCT concat(project,'_',serial) FROM Sensors WHERE $MATCH serial REGEXP '${RGN/*_/}' AND active ORDER BY project, datum DESC")
        else      
            RGN=$($MYSQL -e "SELECT DISTINCT concat(project,'_',serial) FROM Sensors WHERE project = '$RGN' AND active ORDER BY project, datum DESC")
        fi
        for KIT in $RGN
        do
            if echo "$KITS" | grep -q "$KIT" ; then continue ; fi
            # some kit table names carry different regional ID but are in this project
            KITS+=' '
            if ! echo "$TBLS" | grep -q "$KIT"
            then
                KITS+=$($MYSQL -e "SHOW TABLES LIKE '%${KIT/*_/_/}'")
            else
                KITS+=${KIT}
            fi
        done
    done
    echo "$KITS"
}

declare -i PRTCMD=0
function PrtCmd(){
    if (( $PRTCMD > 0 )) ; then return ; fi
    PRTCMD=1
    echo "Command $CMD" 1>&2
}

# get last NR measurements of a kit from DB into error file
function LastSensed() {
    local NME="$1" ; shift
    if [ -z "$NME" ] || [ $($MYSQL -e "SHOW TABLES LIKE '$NME'") != "$NME" ]
    then
        echo "No DB table $NME found."
        return 1
    fi
    local NR=${1:-12} ; shift
    local POL=''
    ACT=$(echo "${DUST//[()|]/ } ${METEO//[()|]/ }" | sed -e 's/^  *//' -e 's/  *$//' -e 's/  */ /g')
    if [ -z "$1" ] ; then return 0 ; fi
    while [ -n "$1" ]
    do
        if echo "$ACT" | grep -q "$1"
        then
            ACT=$(echo "$ACT" | sed -e "s/^$1 *//" -e "s/$1 *//" -e 's/  *$//')
        fi
        POL+=",$1 AS '$1*'"
        shift
    done
    if [ -n "$ACT" ] ; then ACT=",$ACT" ; fi
    echo "Selection of recent measurements of $NME in database table for (*failing) sensors:"
    $MYSQL --table --column-names -e "SELECT datum as 'MET timestamp'${ACT// /,}$POL FROM $NME ORDER BY datum DESC LIMIT ${NR}"
    return $?
}

# check what to do
KITS=''
if [ -z "$1" ] && [ -n "$REGION" ] # region defined: check all active kits in that region
then
    KITS=$(GetRegionalKits $REGION)       
elif [ -n "$1" ]  # no region defined, there are arguments kits or region
then
    KITS=$(GetRegionalKits $@)
fi

for KIT in $KITS
do
  LOCATION=''
  CheckSensors "$KIT" "$START" "$LAST" 2>/var/tmp/Check$$  # is producing data
  for SENSOR in ${ActiveSenses[@]}
  do
    if ! echo "$SENSOR" | grep -q -P "$SENSORS" ; then continue ; fi
    # look into meteo sensor actives for static values in this period: failing sensors
    if ! NrValids "$KIT" "$SENSOR" "$START" "$LAST" 2>/var/tmp/CheckVal$$
    then
        # if ! LastMeasurement "$KIT" "$START" "$LAST" 2>>/var/tmp/CheckVal$$
        # then
        #     SENSOR+=' and other meteo/dust sensors'
        # fi
        if (( $VERBOSE > 0 ))
        then
            PrtCmd
            echo -e "\n${RED}${KIT} sensor $SENSOR is NOT OK.${NOCOLOR}" 1>&2
        fi
        cat /var/tmp/CheckVal$$ >>/var/tmp/Check$$
        NotActiveSenses[${#NotActiveSenses[@]}]=$SENSOR # sensor is inactive
        for (( I=0; I < ${#ActiveSenses[@]} ; I++))
        do if [ "${ActiveSenses[$I]}" = "$SENSOR" ] ; then ActiveSenses[$I]=" " ; break ; fi
        done
     elif (( $VERBOSE > 0 ))
     then
        PrtCmd
        echo -e "\n${GREEN}${KIT} sensor $SENSOR is OK.${NOCOLOR}" 1>&2
        if (( $VERBOSE > 1 )) ; then cat /var/tmp/CheckVal$$ 1>&2 ; fi
    fi
    rm -f /var/tmp/CheckVal$$
  done
  if [ -s /var/tmp/Check$$ ] # there is a failure message
  then
      PrtCmd
      if [ -z "$LOCATION" ] ; then LOCATION=$(GetLblLocation "$KIT" ) ; fi
      echo -e "\n$KIT: ${LOCATION:-${RED}no location${NOCOLOR} details defined}" 1>&2
      if (( $VERBOSE > 0 ))
      then
        cat /var/tmp/Check$$ 1>&2
      fi
      if (( ${#ActiveSenses[@]} <= 0 ))
      then
        echo -e "${RED}$KIT is not measuring in period $START up to $LAST!${NOCOLOR}" 1>&2
        echo -e "$KIT is not operational! No measurements in period $START up to $LAST." >/var/tmp/Check$$
      fi
      if (( ${#NotActiveSenses[@]} > 0 ))
      then
        echo -e "${RED}$KIT has problems with sensor: ${NotActiveSenses[@]}!${NOCOLOR}" 1>&2
        LastSensed $KIT 12 ${NotActiveSenses[@]} | tee -a /var/tmp/Check$$ | head --lines=6 1>&2
      fi
      if ! SendNotice "$KIT" "$SENSOR" /var/tmp/Check$$
      then
           echo -e "${RED}FAILURE to send Notice${NOCOLOR} about kit $KIT, failing sensors ${NotActiveSenses[@]}" 1>&2
      fi
      rm -f /var/tmp/Check$$
  elif (( $VERBOSE > 0 ))
  then
      PrtCmd
      if [ -z "$LOCATION" ] ; then LOCATION=$(GetLblLocation "$KIT" ) ; fi
      echo -e "\n$KIT: ${LOCATION:-${RED}no location${NOCOLOR} details defined}" 1>&2
      echo -e "${GREEN}$KIT is OK${NOCOLOR} with sensors: ${ActiveSenses[@]}!" 1>&2
  fi
done
# save notices history
if [ -s ~/.ATTENTS.sh ] ; then rm -f ~/.ATTENTS.sh ; fi
if (( ${#ATTENT[@]} > 0 ))
then
    echo "#
# $CMD: file created or modified  at $(DATE)
# notices and dates/time sent
#" >~/.ATTENTS.sh
fi

for KIT in ${!ATTENT[@]}
do
    echo "ATTENT[$KIT]=${ATTENT[$KIT]} # $(DATE ${ATTENT[$KIT]})" >> ~/.ATTENTS.sh
done
