#!/usr/bin/with-contenv bashio

aryDiscTopic=()
pub_args=()
while getopts h:p:u:P:c:w: flag
do
    case "${flag}" in
        h|p|u|P) pub_args+=("-${flag}" ${OPTARG});;
        c) CONFIG_PATH=${OPTARG};;
        w) CONFIG_DATA_PATH=${OPTARG};;
    esac
done

# Get discovery_prefix
if bashio::config.exists "mqtt.discovery_prefix"
then MQTT_DISCOVERY_PREFIX=$(bashio::config "mqtt.discovery_prefix")
else MQTT_DISCOVERY_PREFIX=$(bashio::services mqtt "discovery_prefix"); fi
if [ "${MQTT_DISCOVERY_PREFIX+true}" ] || [ $MQTT_DISCOVERY_PREFIX != "null" ];
then MQTT_DISCOVERY_PREFIX="homeassistant"; fi


# Is MQTT discovery enabled?
CONFIG_MQTTDISCOVERY_ENABLED="$(jq --raw-output -c -M '.enable_mqtt_discovery' $CONFIG_PATH)"
if [ $CONFIG_MQTTDISCOVERY_ENABLED == "true" ]; then
    bashio::log.info "\nMQTT Discovery ..."

    # Copy template files
    [ ! -d $CONFIG_DATA_PATH/etc/mqtt_discovery ] && mkdir -p $CONFIG_DATA_PATH/etc/mqtt_discovery
    cp -u /mqtt_discovery/* ${CONFIG_DATA_PATH}/etc/mqtt_discovery/ 2>/dev/null || true

    # Enumerate defined meters
    IFS=$'\n'
    for meter in $(jq -c -M '.meters[]' $CONFIG_PATH)
    do 
        declare -A aryKV
        declare kv
        for line in $(printf '%s\n' $meter | jq --raw-output -c -M '.')
        do
            aryKV["name"]=$(printf '%s\n' $meter | jq --raw-output -c -M '.name')
            aryKV["id"]=$(printf '%s\n' $meter | jq --raw-output -c -M '.id')
            aryKV["driver"]=$(printf '%s\n' $meter | jq --raw-output -c -M '.driver')
            aryKV["driver"]=${aryKV["driver"]%%:*}

        done
        bashio::log.info " Adding meter: ${aryKV['name']} ..."

        if [ "${aryKV['id']+true}" ] && [ "${aryKV['driver']+true}" ] ; then
            file="$CONFIG_DATA_PATH/etc/mqtt_discovery/${aryKV['driver']}.json"
            if test -f "$file"; then

                for attribute in $(jq --raw-output -c -M '. | keys[]' $file)
                do
                    #echo "Attribute: ${attribute}"
                    aryKV["attribute"]=$attribute

                    filter=".${attribute}.component"
                    component=$(jq --raw-output -c -M $filter $file)
                    if [[ ! -z "$component" ]] && [ $component != "null" ] ; then
                        topic="$MQTT_DISCOVERY_PREFIX/$component/wmbusmeters/${aryKV['id']}_$attribute/config"

                        filter=".${attribute}.discovery_payload"
                        payload=$(jq --raw-output -c -M $filter $file)

                        for key in ${!aryKV[@]}; do                                                              
                            payload="${payload//\{$key\}/${aryKV[${key}]}}"
                            #echo ${key} ${aryKV[${key}]}                                                             
                        done
                        bashio::log.info "  Add/update topic: $topic"
                        #echo "  Payload: $payload"
                        aryDiscTopic+=($topic)
                        /usr/bin/mosquitto_pub ${pub_args[@]} -r -t "${topic}" -m "${payload}"
                    fi
                done
            else
                bashio::log.info "  File $file not found."
            fi
        fi
    done

fi

bashio::log.info "MQTT Discovery cleanup..."
ramtmp="$(mktemp -p /dev/shm/)"
/usr/bin/mosquitto_sub ${pub_args[@]} -t "$MQTT_DISCOVERY_PREFIX/+/wmbusmeters/+/config" --retained-only -F "%t" > $ramtmp & PID=$!
sleep 1
kill $PID

readarray -t aryReadTopic < $ramtmp;
rm $ramtmp
for topic in ${aryReadTopic[@]}
do
    if [[ ! ${aryDiscTopic[@]} =~ $topic ]]; then
        bashio::log.info " Removing topic: $topic"
        /usr/bin/mosquitto_pub ${pub_args[@]} -r -t "${topic}" -n
    fi
done

